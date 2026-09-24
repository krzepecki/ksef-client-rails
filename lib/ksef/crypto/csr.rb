# frozen_string_literal: true

require "openssl"
require "base64"

module Ksef
  module Crypto
    # PKCS#10 CSR generator for KSeF certificate enrollment.
    #
    # The DN comes from `GET /certificates/enrollments/data`; RDN order and ASN.1 types mirror C#
    # `CreateSubjectDistinguishedName` (see {SUBJECT_FIELDS}). RSA signing uses PKCS#1 v1.5
    # (Java's choice, not C#'s PSS); EC P-256 is the recommended key.
    module Csr
      # RDN order: [OID, response field method, ASN.1 type].
      SUBJECT_FIELDS = [
        ["2.5.4.3",  "commonName",             OpenSSL::ASN1::UTF8STRING],
        ["2.5.4.4",  "surname",                OpenSSL::ASN1::UTF8STRING],
        ["2.5.4.42", "givenName",              OpenSSL::ASN1::UTF8STRING],
        ["2.5.4.10", "organizationName",       OpenSSL::ASN1::UTF8STRING],
        ["2.5.4.97", "organizationIdentifier", OpenSSL::ASN1::UTF8STRING],
        ["2.5.4.6",  "countryName",            OpenSSL::ASN1::PRINTABLESTRING],
        ["2.5.4.5",  "serialNumber",           OpenSSL::ASN1::PRINTABLESTRING],
        ["2.5.4.45", "uniqueIdentifier",       OpenSSL::ASN1::UTF8STRING]
      ].freeze

      # CSR generation result: the request plus the private key (both Base64/PEM).
      Result = Struct.new(:csr_der_base64, :private_key, keyword_init: true) do
        # @return [String] private key in PEM format
        def private_key_pem
          private_key.to_pem
        end

        # @return [String] private key in DER, Base64-encoded (as in the SDKs)
        def private_key_der_base64
          Base64.strict_encode64(private_key.to_der)
        end

        # The private key never goes to error pages, `pp` output or exception reports.
        # @return [String]
        def inspect
          "#<#{self.class.name} csr_der_base64=#{csr_der_base64.inspect} private_key=[REDACTED]>"
        end
        alias_method :to_s, :inspect

        # `pp` and IRB print through #pretty_print, which Struct implements without calling #inspect.
        def pretty_print(printer)
          printer.text(inspect)
        end
      end

      module_function

      # Generates a CSR with an RSA-2048 key (SHA256 PKCS#1 v1.5 signature).
      # @param enrollment_data [Hash] the /certificates/enrollments/data response
      # @return [Result]
      def generate_rsa(enrollment_data)
        key = OpenSSL::PKey::RSA.new(2048)
        build_request(enrollment_data, key)
      end

      # Generates a CSR with an EC P-256 key (recommended; ECDSA-SHA256 signature).
      # @param enrollment_data [Hash] the /certificates/enrollments/data response
      # @return [Result]
      def generate_ecdsa(enrollment_data)
        key = OpenSSL::PKey::EC.generate("prime256v1")
        build_request(enrollment_data, key)
      end

      # Builds and signs the CSR with the given key.
      # @param enrollment_data [Hash]
      # @param key [OpenSSL::PKey::PKey]
      # @return [Result]
      def build_request(enrollment_data, key)
        request = OpenSSL::X509::Request.new
        request.version = 0
        request.subject = build_subject(enrollment_data)
        request.public_key = public_key_of(key)
        request.sign(key, OpenSSL::Digest.new("SHA256"))

        Result.new(csr_der_base64: Base64.strict_encode64(request.to_der), private_key: key)
      end

      # Builds the DN preserving order and ASN.1 types (empty fields are skipped).
      # @param data [Hash]
      # @return [OpenSSL::X509::Name]
      def build_subject(data)
        name = OpenSSL::X509::Name.new
        SUBJECT_FIELDS.each do |oid, field, asn1_type|
          value = data[field] || data[field.to_sym]
          next if value.nil? || value.to_s.empty?

          name.add_entry(oid, value.to_s, asn1_type)
        end
        name
      end

      # Extracts the public key (SPKI) regardless of type (RSA/EC).
      # On OpenSSL 3.0 keys are immutable, so we round-trip through DER SubjectPublicKeyInfo.
      # @param key [OpenSSL::PKey::PKey]
      # @return [OpenSSL::PKey::PKey] a key holding only the public part
      def public_key_of(key)
        OpenSSL::PKey.read(key.public_to_der)
      end
    end
  end
end
