# frozen_string_literal: true

require "openssl"

# Test helpers generating self-signed certificates (the equivalent of C#'s CertificateBuilders).
# The KSeF TEST environment accepts self-signed certificates for authentication.
module CertificateHelper
  module_function

  # @param key [OpenSSL::PKey::PKey] key (RSA or EC)
  # @param subject [String, OpenSSL::X509::Name] DN in OpenSSL notation, or a Name
  # @return [OpenSSL::X509::Certificate]
  def self_signed(key, subject: "/CN=Test Subject/O=ACME/C=PL/serialNumber=NIP-5555555555")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 0x0123456789ABCDEF
    name = subject.is_a?(OpenSSL::X509::Name) ? subject : OpenSSL::X509::Name.parse(subject)
    cert.subject = name
    cert.issuer = name
    cert.public_key = OpenSSL::PKey.read(key.public_to_der)
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + (3600 * 24 * 365)
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert
  end

  # @return [Array(OpenSSL::X509::Certificate, OpenSSL::PKey::RSA)]
  def rsa_pair
    key = OpenSSL::PKey::RSA.new(2048)
    [self_signed(key), key]
  end

  # @return [Array(OpenSSL::X509::Certificate, OpenSSL::PKey::EC)]
  def ec_pair
    key = OpenSSL::PKey::EC.generate("prime256v1")
    [self_signed(key), key]
  end
end
