# frozen_string_literal: true

require "openssl"
require "base64"
require "digest"
require "date"
require "nokogiri"
require "ksef/errors"
require "ksef/models/nip"

module Ksef
  module Qr
    # Builds KSeF verification links for QR codes. CODE I is
    # `{qr}/invoice/{nip}/{DD-MM-YYYY}/{hash}`; CODE II appends a signature over the path fragment
    # taken WITHOUT the `https://` prefix and trailing `/` (RSASSA-PSS or ECDSA P-256, Base64URL).
    class VerificationLink
      # Context identifier type → the pattern of its value in the contract.
      CONTEXT_TYPES = {
        "Nip" => Nip::PATTERN,
        "InternalId" => /\A[1-9]((\d[1-9])|([1-9]\d))\d{7}-\d{5}\z/,
        "NipVatUe" => /\A[1-9]((\d[1-9])|([1-9]\d))\d{7}-[A-Z]{2}[A-Z0-9+*]{2,12}\z/,
        "PeppolId" => /\AP[A-Z]{2}\d{6}\z/
      }.freeze
      # The authentication API's context keys ({Ksef::Auth::Coordinator::CONTEXT_TYPES}).
      CONTEXT_KEYS = { nip: "Nip", internal_id: "InternalId", nip_vat_ue: "NipVatUe", peppol_id: "PeppolId" }.freeze
      DATE_SEGMENT = /\A\d{2}-\d{2}-\d{4}\z/
      # A KSeF certificate serial number: 16 uppercase hex digits.
      SERIAL_SEGMENT = /\A[0-9A-F]{16}\z/

      # @param qr_base_url [String] environment QR host (e.g. "https://qr-test.ksef.mf.gov.pl")
      def initialize(qr_base_url:)
        @qr_base_url = qr_base_url.chomp("/")
      end

      # Builds one from the client configuration.
      # @param client [Ksef::Client]
      # @return [VerificationLink]
      def self.from_client(client)
        new(qr_base_url: client.config.qr_url)
      end

      # CODE I — link to an online invoice.
      #
      # @param seller_nip [String, Ksef::Nip] seller tax ID; separators and a "PL" prefix are stripped
      # @param issue_date [Date, String, nil] issue date (P_1): a Date, "YYYY-MM-DD" or "DD-MM-YYYY"; nil reads
      #   `Fa/P_1` from invoice_xml. A Time is refused — its calendar day depends on its zone.
      # @param invoice_xml [String, nil] invoice content (to compute the digest)
      # @param invoice_hash [String, nil] precomputed SHA-256 digest, Base64URL or Base64 (as KSeF's
      #   `invoiceHash`), instead of invoice_xml — then with issue_date, as there is no P_1 to read
      # @return [String] full URL
      # @raise [Ksef::ConfigurationError] for an invalid NIP, a date missing, invalid or differing from P_1, or
      #   a hash that is not a SHA-256 digest or differs from invoice_xml's
      def online(seller_nip:, issue_date: nil, invoice_xml: nil, invoice_hash: nil)
        hash = invoice_digest(invoice_xml, invoice_hash)
        nip = Nip.normalize!(seller_nip, name: "seller_nip")
        date = link_date(issue_date, invoice_xml)
        "#{@qr_base_url}/invoice/#{nip}/#{date}/#{hash}"
      end

      # CODE II — offline link signed with a KSeF Offline certificate.
      #
      # @param context_type [String, Symbol] "Nip", "InternalId", "NipVatUe" or "PeppolId" — or the
      #   authentication API's :nip, :internal_id, :nip_vat_ue, :peppol_id
      # @param context_value [String] context value (a NIP is normalized like seller_nip)
      # @param seller_nip [String, Ksef::Nip] seller tax ID; separators and a "PL" prefix are stripped
      # @param certificate_serial [String, OpenSSL::BN, Integer] the KSeF Offline certificate's serial number:
      #   16 hex digits (`certificateSerialNumber`), or `certificate.serial`
      # @param private_key [OpenSSL::PKey::RSA, OpenSSL::PKey::EC] signing key: RSA of at least 2048 bits, or
      #   EC P-256
      # @param invoice_xml [String, nil]
      # @param invoice_hash [String, nil] precomputed SHA-256 digest, Base64URL or Base64
      # @return [String] full URL including the signature
      # @raise [Ksef::ConfigurationError] for an invalid NIP, context, serial or hash
      # @raise [Ksef::CryptoError] for a key without its private part, an RSA key under 2048 bits or another curve
      def offline(context_type:, context_value:, seller_nip:, certificate_serial:, private_key:,
                  invoice_xml: nil, invoice_hash: nil)
        hash = invoice_digest(invoice_xml, invoice_hash)
        type = context_type!(context_type)
        base_path = [
          "certificate",
          type,
          context_segment(type, context_value),
          Nip.normalize!(seller_nip, name: "seller_nip"),
          serial!(certificate_serial),
          hash
        ].join("/")
        host_path = "#{host}/#{base_path}" # without the https:// prefix and without a trailing /
        signature = sign_base64url(host_path, private_key)
        "#{@qr_base_url}/#{base_path}/#{signature}"
      end

      private

      def context_type!(value)
        type = value.is_a?(Symbol) ? CONTEXT_KEYS.fetch(value, value.to_s) : value.to_s
        return type if CONTEXT_TYPES.key?(type)

        raise ConfigurationError, "context_type must be one of #{CONTEXT_TYPES.keys.join(', ')}, got #{value.inspect}"
      end

      # A NIP context is normalized like seller_nip; other identifiers must match the contract's pattern.
      def context_segment(type, value)
        return Nip.normalize!(value, name: "context_value") if type == "Nip"

        segment!("context_value", value, CONTEXT_TYPES.fetch(type))
      end

      def serial!(value)
        text = value.is_a?(OpenSSL::BN) || value.is_a?(Integer) ? value.to_s(16).rjust(16, "0") : value.to_s.strip
        segment!("certificate_serial", text.upcase, SERIAL_SEGMENT)
      end

      # The SHA-256 digest as Base64URL without padding: computed from the XML, or decoded from the given
      # hash (Base64 or Base64URL) and re-encoded; both must agree when both are given.
      def invoice_digest(xml, hash)
        computed = xml && Base64.urlsafe_encode64(Digest::SHA256.digest(xml.b), padding: false)
        return computed || raise(ConfigurationError, "Provide invoice_xml or invoice_hash") if hash.nil?

        given = Base64.urlsafe_encode64(decode_hash(hash), padding: false)
        return given if computed.nil? || computed == given

        raise ConfigurationError, "invoice_hash does not match the SHA-256 of invoice_xml"
      end

      def decode_hash(hash)
        text = hash.to_s.strip.tr("+/", "-_").delete("=")
        bytes = Base64.urlsafe_decode64(text + ("=" * ((4 - (text.length % 4)) % 4)))
        return bytes if bytes.bytesize == 32 && Base64.urlsafe_encode64(bytes, padding: false) == text

        raise ArgumentError
      rescue ArgumentError
        raise ConfigurationError, "invoice_hash is not a Base64 SHA-256 digest: #{hash.to_s.inspect}"
      end

      # @return [String] the value, once it is known to be exactly one path segment
      def segment!(name, value, pattern)
        text = value.to_s
        return text if text.match?(pattern)

        raise ConfigurationError, "#{name} is not a valid link segment: #{text.inspect}"
      end

      def host
        @qr_base_url.sub(%r{\Ahttps?://}, "")
      end

      # The verifier looks the invoice up by the link's date, so it must be P_1: a wrong day reads
      # "Faktura nie została znaleziona w KSeF".
      def link_date(issue_date, invoice_xml)
        from_xml = invoice_xml && invoice_p1(invoice_xml)
        given = issue_date && format_date(issue_date)
        if from_xml && given && from_xml != given
          raise ConfigurationError, "issue_date #{given} differs from the invoice's P_1 #{from_xml}"
        end

        given || from_xml || raise(ConfigurationError, "issue_date is required: no Fa/P_1 to read it from")
      end

      def invoice_p1(xml)
        text = Nokogiri::XML(xml).at_xpath("/*[local-name()='Faktura']/*[local-name()='Fa']/*[local-name()='P_1']")&.text
        text && format_date(text.strip)
      end

      def format_date(date)
        if date.is_a?(Time) || date.is_a?(DateTime) # TimeWithZone reports itself as a Time
          raise ConfigurationError, "issue_date must be a Date or a date string, not a #{date.class} — pass P_1"
        end
        return date.strftime("%d-%m-%Y") if date.is_a?(Date)

        text = date.to_s
        return Date.iso8601(text).strftime("%d-%m-%Y") if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        return Date.strptime(text, "%d-%m-%Y").strftime("%d-%m-%Y") if text.match?(DATE_SEGMENT)

        raise Date::Error
      rescue Date::Error
        raise ConfigurationError, "issue_date is not a valid date (YYYY-MM-DD or DD-MM-YYYY): #{date.inspect}"
      end

      # Signs the string according to the key type; result in Base64URL (no padding).
      def sign_base64url(data, key)
        check_key!(key)
        signature = case key
                    when OpenSSL::PKey::RSA
                      key.sign_pss("SHA256", data, salt_length: 32, mgf1_hash: "SHA256")
                    when OpenSSL::PKey::EC
                      ecdsa_p1363(key.sign(OpenSSL::Digest.new("SHA256"), data), key)
                    else
                      raise CryptoError, "Unsupported QR signing key: #{key.class}"
                    end
        Base64.urlsafe_encode64(signature, padding: false)
      end

      # The keys a KSeF Offline certificate can carry (kody-qr.md): RSA of 2048 bits or more, EC P-256.
      def check_key!(key)
        return unless key.is_a?(OpenSSL::PKey::RSA) || key.is_a?(OpenSSL::PKey::EC)
        raise CryptoError, "the QR signing key has no private part" unless key.private?
        if key.is_a?(OpenSSL::PKey::RSA) && key.n.num_bits < 2048
          raise CryptoError, "the QR signing key has #{key.n.num_bits} bits; at least 2048 are required"
        end
        return unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name != "prime256v1"

        raise CryptoError, "the QR signing key is on #{key.group.curve_name}; KSeF requires P-256"
      end

      # ECDSA DER → IEEE P1363 (R‖S) conversion — the recommended form for CODE II.
      def ecdsa_p1363(der, key)
        asn1 = OpenSSL::ASN1.decode(der)
        byte_len = (key.group.degree + 7) / 8
        r = asn1.value[0].value.to_s(2).rjust(byte_len, "\x00")
        s = asn1.value[1].value.to_s(2).rjust(byte_len, "\x00")
        r + s
      end
    end
  end
end
