# frozen_string_literal: true

# Oracle generator (Ruby side): signs an AuthTokenRequest with self-signed RSA, EC P-256 and EC P-384
# certificates, dumping each signed document and its signing certificate for verify_xades.py.
#
# This is the OFFLINE proof for the XAdES signature: reference digests + SignatureValue must be
# cryptographically valid, the ECDSA path must emit R‖S (P1363), not DER, and SigningCertificate
# must describe the certificate that signed.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "json"
require "base64"
require "openssl"
require "ksef/errors"
require "ksef/xades/auth_token_request"
require "ksef/xades/signer"

def self_signed(key, name)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = OpenSSL::BN.new(OpenSSL::Random.random_bytes(8).unpack1("H*").to_i(16).to_s)
  cert.subject = name
  cert.issuer = name
  cert.public_key = OpenSSL::PKey.read(key.public_to_der)
  cert.not_before = Time.now - 3600
  cert.not_after = Time.now + (3600 * 24 * 365)
  ef = OpenSSL::X509::ExtensionFactory.new
  ef.subject_certificate = cert
  ef.issuer_certificate = cert
  cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
  cert.sign(key, OpenSSL::Digest.new("SHA256"))
  cert
end

xml = Ksef::Xades::AuthTokenRequest.new(
  challenge: "20250604-CR-461EA5B000-537A6BA15D-D7",
  context: { nip: "5555555555" },
  subject_identifier_type: :certificate_subject,
  allowed_ips: { addresses: ["1.2.3.4"], masks: ["10.0.0.0/8"] }
).to_xml

person = OpenSSL::X509::Name.parse("/CN=Jan Kowalski/O=ACME/C=PL/serialNumber=NIP-5555555555")
# A seal-style issuer: diacritics, characters RFC 4514 escapes, and an attribute without a short name.
seal = OpenSSL::X509::Name.new([["C", "PL"], ["O", "Zakład Usług „Żółć”, Sp. z o.o.", OpenSSL::ASN1::UTF8STRING],
                                ["2.5.4.97", "VATPL-5555555555", OpenSSL::ASN1::UTF8STRING],
                                ["CN", "Pieczęć #1 + test", OpenSSL::ASN1::UTF8STRING]])
# A BMPString (UTF-16) value and a multi-valued RDN (O + OU in one set).
bmp = OpenSSL::X509::Name.new([["C", "PL"], ["CN", "Żółć".encode("UTF-16BE").b, OpenSSL::ASN1::BMPSTRING]])
bmp.add_entry("O", "Firma", OpenSSL::ASN1::UTF8STRING, loc: 1)
bmp.add_entry("OU", "Dział", OpenSSL::ASN1::UTF8STRING, loc: 1, set: 1)
signers = {
  "RSA" => [OpenSSL::PKey::RSA.new(2048), person],
  "EC P-256" => [OpenSSL::PKey::EC.generate("prime256v1"), person],
  "EC P-384" => [OpenSSL::PKey::EC.generate("secp384r1"), seal],
  "EC P-256, BMPString and multi-valued issuer" => [OpenSSL::PKey::EC.generate("prime256v1"), bmp]
}

documents = signers.map do |label, (key, name)|
  cert = self_signed(key, name)
  { "label" => label, "signed_xml" => Ksef::Xades::Signer.new(cert: cert, key: key).sign(xml),
    "certificate_der_b64" => Base64.strict_encode64(cert.to_der) }
end
# A top-level processing instruction belongs to the URI="" reference too.
key = OpenSSL::PKey::RSA.new(2048)
cert = self_signed(key, person)
with_pi = xml.sub(/\A(<\?xml[^>]*\?>\s*)/) { "#{Regexp.last_match(1)}<?ksef-oracle test?>\n" }
raise "no processing instruction" unless with_pi.include?("<?ksef-oracle")

documents << { "label" => "RSA, top-level processing instruction",
               "signed_xml" => Ksef::Xades::Signer.new(cert: cert, key: key).sign(with_pi),
               "certificate_der_b64" => Base64.strict_encode64(cert.to_der) }

puts JSON.generate("unsigned_xml" => xml, "documents" => documents)
