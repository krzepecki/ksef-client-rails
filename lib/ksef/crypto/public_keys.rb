# frozen_string_literal: true

require "openssl"
require "base64"
require "time"

module Ksef
  module Crypto
    # Fetches, caches and selects the Ministry of Finance public-key certificates by usage
    # (`GET /security/public-key-certificates`, anonymous). {#with_rotation_retry} refreshes them
    # on error 21470 — both SDKs leave that refresh to the caller.
    class PublicKeys
      # Certificate usages (values of the PublicKeyCertificateUsage enum).
      SYMMETRIC_KEY_ENCRYPTION = "SymmetricKeyEncryption"
      KSEF_TOKEN_ENCRYPTION = "KsefTokenEncryption"
      # API error code: the data was encrypted under a certificate that has since been rotated.
      KEY_ROTATED = 21_470

      ENDPOINT = "/security/public-key-certificates"

      # A single Ministry of Finance public-key certificate.
      Certificate = Struct.new(:certificate_der, :certificate_id, :public_key_id,
                               :valid_from, :valid_to, :usages, keyword_init: true) do
        # @param usage [String]
        # @return [Boolean] whether the certificate may be used for the given usage
        def usable_for?(usage)
          usages.include?(usage)
        end

        # @param time [Time]
        # @return [Boolean] whether the certificate is valid at the given moment
        def valid_at?(time)
          valid_from <= time && time < valid_to
        end

        # @return [OpenSSL::X509::Certificate] parsed certificate (memoized)
        def openssl_certificate
          @openssl_certificate ||= OpenSSL::X509::Certificate.new(certificate_der)
        end

        # @return [OpenSSL::PKey::PKey] public key (RSA or EC)
        def public_key
          openssl_certificate.public_key
        end
      end

      # @param connection [Ksef::Http::Connection] HTTP connection (anonymous call)
      # @param logger [Logger, nil]
      # @param clock [#call] time source (for tests); defaults to -> { Time.now }
      def initialize(connection:, logger: nil, clock: -> { Time.now })
        @connection = connection
        @logger = logger
        @clock = clock
        @cache = nil
        @mutex = Mutex.new
      end

      # Returns the certificate list (cached; fetched on first call or when +force+).
      # @param force [Boolean] force a refetch
      # @return [Array<Certificate>]
      def all(force: false)
        @mutex.synchronize do
          @cache = fetch_certificates if force || @cache.nil?
          @cache
        end
      end

      # Picks the newest valid RSA certificate for the given usage — the gem wraps keys and tokens with
      # RSA-OAEP only. When the cached list has none (the cache outlived a rotation in a long-running
      # process), it refetches once before giving up.
      # @param usage [String] SYMMETRIC_KEY_ENCRYPTION or KSEF_TOKEN_ENCRYPTION
      # @return [Certificate]
      # @raise [Ksef::CryptoError] when no valid certificate is available
      def for_usage(usage)
        select_certificate(usage) || select_certificate(usage, force: true) ||
          raise(CryptoError, "No valid Ministry of Finance RSA certificate for usage: #{usage}")
      end

      # Forces a refetch of the certificates (e.g. after rotation error 21470).
      # @return [Array<Certificate>]
      def refresh!
        @logger&.info("[ksef] refreshing Ministry of Finance public-key certificates (rotation)")
        all(force: true)
      end

      # Runs the block; when the API answers 21470, refetches the certificates and runs it once more
      # with +true+, so the caller re-encrypts with the new key.
      # @yieldparam retrying [Boolean]
      # @return [Object] the block's result
      def with_rotation_retry
        yield(false)
      rescue ApiError => e
        raise unless e.codes.include?(KEY_ROTATED)

        refresh!
        yield(true)
      end

      private

      def select_certificate(usage, force: false)
        now = @clock.call
        all(force: force)
          .select { |c| c.usable_for?(usage) && c.valid_at?(now) && c.public_key.is_a?(OpenSSL::PKey::RSA) }
          .max_by(&:valid_from)
      end

      def fetch_certificates
        response = @connection.get(ENDPOINT)
        Array(response.body).map { |item| build_certificate(item) }
      end

      def build_certificate(item)
        Certificate.new(
          certificate_der: Base64.decode64(item["certificate"]),
          certificate_id: item["certificateId"],
          public_key_id: item["publicKeyId"],
          valid_from: Time.iso8601(item["validFrom"]),
          valid_to: Time.iso8601(item["validTo"]),
          usages: Array(item["usage"])
        )
      end
    end
  end
end
