# frozen_string_literal: true

require "openssl"

# Signing material from the demo form: a certificate + key pair (PEM or DER — KSeF hands out the
# certificate as DER, and its app saves the pair as `*.cert` + `*.key`), the two of them in one PEM
# file, or a PKCS#12. One password field covers PKCS#12 and an encrypted key.
class CertificateUpload
  # PEM blocks are pulled out explicitly — OpenSSL 3 does not reliably skip a leading certificate
  # when asked for a key.
  PEM_CERTIFICATE = /-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m
  PEM_PRIVATE_KEY = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m

  # @param certificate [String, nil] uploaded certificate file (PEM or PKCS#12)
  # @param key [String, nil] uploaded private key file (PEM), optional
  # @param password [String] PKCS#12 / encrypted key password ("" — never nil, or OpenSSL prompts)
  def initialize(certificate:, key: nil, password: "")
    @certificate_data = certificate
    @key_data = key
    @password = password.to_s
  end

  # @return [Array(OpenSSL::X509::Certificate, OpenSSL::PKey::PKey)]
  def certificate_and_key
    @certificate_and_key ||= load_material
  end

  # Diagnostics printed by the demo — the fingerprint is what `certificateFingerprint`
  # authentication and permission grants are keyed on.
  # @return [Hash]
  def info
    cert, key = certificate_and_key
    {
      "subject" => cert.subject.to_s(OpenSSL::X509::Name::RFC2253),
      "issuer" => cert.issuer.to_s(OpenSSL::X509::Name::RFC2253),
      "serial (hex)" => cert.serial.to_s(16).upcase,
      "valid from" => cert.not_before,
      "valid until" => cert.not_after,
      "key" => "#{key.class.name.split('::').last} #{key_bits(key)} bit",
      "matches the private key" => cert.check_private_key(key),
      "SHA-256 fingerprint" => OpenSSL::Digest::SHA256.hexdigest(cert.to_der).upcase
    }
  end

  private

  def load_material
    raise ArgumentError, "Select a certificate file (PEM, DER or PKCS#12)" if @certificate_data.nil?
    return pkcs12 if pkcs12?

    [certificate, private_key]
  end

  # PKCS#12 opens with an INTEGER (version); a DER certificate opens with a SEQUENCE
  # (tbsCertificate) — enough to tell the two binary formats apart without guess-parsing.
  def pkcs12?
    return false if @certificate_data.include?("-----BEGIN")

    OpenSSL::ASN1.decode(@certificate_data).value.first.is_a?(OpenSSL::ASN1::Integer)
  rescue OpenSSL::ASN1::ASN1Error
    false
  end

  def pkcs12
    p12 = OpenSSL::PKCS12.new(@certificate_data, @password)
    [p12.certificate, p12.key]
  end

  def certificate
    OpenSSL::X509::Certificate.new(@certificate_data[PEM_CERTIFICATE] || @certificate_data)
  rescue OpenSSL::X509::CertificateError
    raise ArgumentError, "Unreadable certificate — expected PEM, DER or PKCS#12"
  end

  def private_key
    data = @key_data || @certificate_data
    if data.equal?(@certificate_data) && !data[PEM_PRIVATE_KEY]
      raise ArgumentError, "Select the private key file — the certificate file carries no PRIVATE KEY block"
    end

    OpenSSL::PKey.read(data[PEM_PRIVATE_KEY] || data, @password)
  rescue OpenSSL::PKey::PKeyError
    raise ArgumentError, "Unreadable private key — wrong password, or the file is not a PEM/DER key"
  end

  def key_bits(key)
    key.is_a?(OpenSSL::PKey::EC) ? key.group.degree : key.n.num_bits
  end
end
