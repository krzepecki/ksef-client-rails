# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "time"
require "ksef"

Ksef.require_optional("webmock", "Ksef::Testing")

module Ksef
  # WebMock stubs of the endpoints behind the gem's flows, for an application's own tests: `require
  # "ksef/testing"` and `include Ksef::Testing` where WebMock is enabled. Not loaded by `require "ksef"`.
  # Responses follow the contract's schemas; the Ministry certificate is a real key the gem encrypts with.
  module Testing
    include WebMock::API

    # Test value handed out by {#stub_ksef_authentication}.
    ACCESS_TOKEN = "ksef-test-access-token"
    # Test value handed out by {#stub_ksef_authentication}.
    REFRESH_TOKEN = "ksef-test-refresh-token"
    # Reference number of the session opened by {#stub_ksef_online_session}.
    SESSION_REFERENCE = "20261012-SO-0000000000-0000000000-01"
    # Reference number of each invoice sent through {#stub_ksef_online_session}.
    INVOICE_REFERENCE = "20261012-EE-0000000000-0000000000-01"
    # Validity of the stubbed Ministry certificate: fixed and wide, so that a test that travels in time
    # (travel_to, Timecop) still finds it valid.
    CERTIFICATE_VALIDITY = (Time.utc(2000, 1, 1)..Time.utc(2099, 12, 31))

    # The Ministry public-key certificates (both encryption usages).
    # @param config [Ksef::Configuration] whose environment is stubbed
    # @return [WebMock::RequestStub]
    def stub_ksef_public_keys(config: Ksef.config)
      stub_request(:get, "#{config.api_url}/security/public-key-certificates")
        .to_return(Testing.json(Testing.ministry_certificates))
    end

    # Sign-in with a KSeF token or an XAdES signature — challenge, submission, status 200, redemption —
    # and the access token refresh. Stubs the public keys too (the token is encrypted with them).
    # @param config [Ksef::Configuration]
    # @param access_token [String] handed out on redemption and refresh
    # @param refresh_token [String]
    # @return [void]
    def stub_ksef_authentication(config: Ksef.config, access_token: ACCESS_TOKEN, refresh_token: REFRESH_TOKEN)
      api = config.api_url
      stub_ksef_public_keys(config: config)
      stub_request(:post, "#{api}/auth/challenge").to_return(Testing.json(Testing.challenge))
      init = Testing.json({ referenceNumber: "20261012-AU-0000000000-0000000000-01",
                            authenticationToken: Testing.token("ksef-test-authentication-token") }, status: 202)
      stub_request(:post, "#{api}/auth/ksef-token").to_return(init)
      stub_request(:post, "#{api}/auth/xades-signature").with(query: hash_including({})).to_return(init)
      stub_request(:get, %r{\A#{Regexp.escape(api)}/auth/\d{8}-AU-}).to_return(Testing.json(Testing.auth_status))
      stub_request(:post, "#{api}/auth/token/redeem").to_return(
        Testing.json({ accessToken: Testing.token(access_token),
                       refreshToken: Testing.token(refresh_token, 7 * 86_400) })
      )
      refreshed = Testing.json({ accessToken: Testing.token(access_token) })
      stub_request(:post, "#{api}/auth/token/refresh").to_return(refreshed)
    end

    # An interactive session in which every invoice is accepted: open, send, close, the invoice status
    # (200, with +ksef_number+) and its UPO. Stubs the public keys too.
    # @param ksef_number [String] KSeF number of the accepted invoices; a valid one by default
    # @param upo [String] UPO XML returned for them
    # @param config [Ksef::Configuration]
    # @return [void]
    def stub_ksef_online_session(ksef_number: Testing.ksef_number, upo: "<Potwierdzenie/>", config: Ksef.config)
      api = config.api_url
      session = "#{api}/sessions/online/#{SESSION_REFERENCE}"
      invoice = "#{api}/sessions/#{SESSION_REFERENCE}/invoices/#{INVOICE_REFERENCE}"
      stub_ksef_public_keys(config: config)
      stub_request(:post, "#{api}/sessions/online").to_return(
        Testing.json({ referenceNumber: SESSION_REFERENCE, validUntil: (Time.now + 43_200).utc.iso8601 }, status: 201)
      )
      sent = Testing.json({ referenceNumber: INVOICE_REFERENCE }, status: 202)
      stub_request(:post, "#{session}/invoices").to_return(sent)
      stub_request(:post, "#{session}/close").to_return(status: 204)
      stub_request(:get, invoice).to_return(Testing.json(Testing.accepted_invoice(ksef_number)))
      stub_request(:get, "#{invoice}/upo").to_return(status: 200, headers: { "Content-Type" => "application/xml" },
                                                     body: upo)
    end

    class << self
      # A KSeF number with a valid checksum.
      # @param seller_nip [String] spaces, hyphens and a "PL" prefix are stripped
      # @param date [Date]
      # @return [String]
      # @raise [Ksef::ConfigurationError] for an invalid NIP, or a date the KSeF number pattern refuses
      def ksef_number(seller_nip: "5555555555", date: Date.new(2026, 10, 12))
        data = "#{Nip.normalize!(seller_nip, name: 'seller_nip')}-#{date.strftime('%Y%m%d')}-0100001AF629"
        KsefNumber.new("#{data}-#{format('%02X', KsefNumber.crc8(data))}").validate!.to_s
      end

      # @api private
      def ministry_certificates
        @ministry_certificates ||= begin
          der = Base64.strict_encode64(ministry_certificate.to_der)
          %w[SymmetricKeyEncryption KsefTokenEncryption].map do |usage|
            { certificate: der, certificateId: Base64.strict_encode64("test-#{usage}"), usage: [usage],
              publicKeyId: Base64.strict_encode64(usage.ljust(32, "0")),
              validFrom: CERTIFICATE_VALIDITY.begin.iso8601, validTo: CERTIFICATE_VALIDITY.end.iso8601 }
          end
        end
      end

      # @api private
      def json(body, status: 200)
        { status: status, headers: { "Content-Type" => "application/json" }, body: JSON.generate(body) }
      end

      # @api private
      def token(value, seconds = 900)
        { token: value, validUntil: (Time.now + seconds).utc.iso8601 }
      end

      # @api private
      def challenge
        now = Time.now
        { challenge: "20261012-CR-0000000000-0000000000-01", timestamp: now.utc.iso8601(3),
          timestampMs: (now.to_f * 1000).to_i, clientIp: "127.0.0.1" }
      end

      # @api private
      def auth_status
        { startDate: Time.now.utc.iso8601, authenticationMethod: "Token",
          authenticationMethodInfo: { category: "Token", code: "token", displayName: "Token KSeF" },
          status: { code: 200, description: "Uwierzytelnianie zakończone sukcesem" } }
      end

      # @api private
      def accepted_invoice(ksef_number)
        { ordinalNumber: 1, referenceNumber: INVOICE_REFERENCE, ksefNumber: ksef_number,
          invoiceHash: Base64.strict_encode64("0" * 32), invoicingDate: Time.now.utc.iso8601,
          status: { code: 200, description: "Sukces" } }
      end

      private

      def ministry_certificate
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=KSeF test Ministry key")
        cert.public_key = key.public_key
        cert.not_before = CERTIFICATE_VALIDITY.begin
        cert.not_after = CERTIFICATE_VALIDITY.end
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert
      end
    end
  end
end
