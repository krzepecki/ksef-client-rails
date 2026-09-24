# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Xades::AuthTokenRequest do
  let(:challenge) { "20250604-CR-461EA5B000-537A6BA15D-D7" }

  it "builds XML matching the schema (ns, Challenge, ContextIdentifier/Nip, SubjectIdentifierType)" do
    xml = described_class.new(
      challenge: challenge,
      context: { nip: "5555555555" },
      subject_identifier_type: :certificate_subject
    ).to_xml
    doc = Nokogiri::XML(xml)
    ns = { "t" => described_class::NAMESPACE }
    expect(doc.at_xpath("/t:AuthTokenRequest/t:Challenge", ns).text).to eq(challenge)
    expect(doc.at_xpath("//t:ContextIdentifier/t:Nip", ns).text).to eq("5555555555")
    expect(doc.at_xpath("//t:SubjectIdentifierType", ns).text).to eq("certificateSubject")
  end

  it "normalizes a NIP context and refuses an invalid one" do
    xml = described_class.new(challenge: challenge, context: { nip: "PL 526-025-02-74" }).to_xml
    ns = { "t" => described_class::NAMESPACE }
    expect(Nokogiri::XML(xml).at_xpath("//t:ContextIdentifier/t:Nip", ns).text).to eq("5260250274")
    expect { described_class.new(challenge: challenge, context: { nip: "1234567890" }) }
      .to raise_error(Ksef::ConfigurationError, /context nip/)
  end

  it "adds AuthorizationPolicy with AllowedIps" do
    xml = described_class.new(
      challenge: challenge,
      context: { nip: "5555555555" },
      allowed_ips: { addresses: ["1.2.3.4"], masks: ["10.0.0.0/8"] }
    ).to_xml
    ns = { "t" => described_class::NAMESPACE }
    doc = Nokogiri::XML(xml)
    expect(doc.at_xpath("//t:AllowedIps/t:Ip4Address", ns).text).to eq("1.2.3.4")
    expect(doc.at_xpath("//t:AllowedIps/t:Ip4Mask", ns).text).to eq("10.0.0.0/8")
  end

  it "accepts allowed_ips with string keys and keeps the XSD element order" do
    xml = described_class.new(challenge: challenge, context: { nip: "5555555555" },
                              allowed_ips: { "masks" => ["10.0.0.0/8"], "addresses" => ["1.2.3.4"] }).to_xml
    names = Nokogiri::XML(xml).xpath("//t:AllowedIps/*", "t" => described_class::NAMESPACE).map(&:name)

    expect(names).to eq(%w[Ip4Address Ip4Mask])
  end

  it "omits the AuthorizationPolicy when allowed_ips has no entries, and rejects unknown keys" do
    xml = described_class.new(challenge: challenge, context: { nip: "5555555555" }, allowed_ips: {}).to_xml

    expect(xml).not_to include("AuthorizationPolicy")
    expect { described_class.new(challenge: challenge, context: { nip: "5555555555" }, allowed_ips: { ips: [] }) }
      .to raise_error(Ksef::ConfigurationError, /allowed_ips/)
  end

  it "rejects an invalid context type" do
    expect do
      described_class.new(challenge: challenge, context: { foo: "x" }).to_xml
    end.to raise_error(Ksef::ConfigurationError)
  end
end

RSpec.describe Ksef::Xades::Signer do
  let(:unsigned_xml) do
    Ksef::Xades::AuthTokenRequest.new(
      challenge: "20250604-CR-461EA5B000-537A6BA15D-D7",
      context: { nip: "5555555555" }
    ).to_xml
  end

  # Verifies the signature in Ruby: exclusive canonicalization of SignedInfo + verify with the
  # certificate key.
  def verify_signed_info(signed_xml, cert)
    doc = Nokogiri::XML(signed_xml)
    ns = { "ds" => Ksef::Xades::Signer::DS_NS }
    signed_info = doc.at_xpath("//ds:SignedInfo", ns)
    c14n = signed_info.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
    sig_value = Base64.strict_decode64(doc.at_xpath("//ds:SignatureValue", ns).text)
    [c14n, sig_value, cert.public_key]
  end

  it "signs with an RSA key — the SignatureValue verifies (rsa-sha256)" do
    cert, key = CertificateHelper.rsa_pair
    signed = described_class.new(cert: cert, key: key).sign(unsigned_xml)
    c14n, sig_value, pub = verify_signed_info(signed, cert)
    expect(pub.verify(OpenSSL::Digest.new("SHA256"), sig_value, c14n)).to be(true)

    doc = Nokogiri::XML(signed)
    ns = { "ds" => Ksef::Xades::Signer::DS_NS }
    expect(doc.at_xpath("//ds:SignatureMethod/@Algorithm", ns).value).to end_with("rsa-sha256")
    expect(doc.xpath("//ds:Reference", ns).size).to eq(2)
  end

  it "signs with an EC key — the SignatureValue is R‖S (64 B) and verifies" do
    cert, key = CertificateHelper.ec_pair
    signed = described_class.new(cert: cert, key: key).sign(unsigned_xml)
    doc = Nokogiri::XML(signed)
    ns = { "ds" => Ksef::Xades::Signer::DS_NS }
    sig_value = Base64.strict_decode64(doc.at_xpath("//ds:SignatureValue", ns).text)
    expect(sig_value.bytesize).to eq(64)

    # R‖S → DER conversion and verification with the EC key.
    half = sig_value.bytesize / 2
    r = OpenSSL::BN.new(sig_value[0, half].unpack1("H*"), 16)
    s = OpenSSL::BN.new(sig_value[half, half].unpack1("H*"), 16)
    der = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
    c14n = doc.at_xpath("//ds:SignedInfo", ns).canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
    expect(cert.public_key.verify(OpenSSL::Digest.new("SHA256"), der, c14n)).to be(true)
  end

  # KSeF checks the declared identifiers, not just the bytes: SHA-256 digests live in the xmlenc
  # namespace (xmldsig only defines SHA-1), and an unlisted URI comes back as 9105 from
  # /auth/xades-signature. The oracle cannot catch this — it hashes with SHA-256 either way.
  it "declares only algorithm identifiers from the KSeF list (podpis-xades.md)" do
    cert, key = CertificateHelper.rsa_pair
    doc = Nokogiri::XML(described_class.new(cert: cert, key: key).sign(unsigned_xml))
    ns = { "ds" => Ksef::Xades::Signer::DS_NS }

    # Both references plus xades:CertDigest — CertDigest/DigestMethod sits in the ds namespace
    # through the default xmlns on QualifyingProperties.
    expect(doc.xpath("//ds:DigestMethod/@Algorithm", ns).map(&:value).uniq)
      .to eq(["http://www.w3.org/2001/04/xmlenc#sha256"])
    expect(doc.at_xpath("//ds:CanonicalizationMethod/@Algorithm", ns).value)
      .to eq("http://www.w3.org/2001/10/xml-exc-c14n#")
    expect(doc.xpath("//ds:Transform/@Algorithm", ns).map(&:value).uniq).to contain_exactly(
      "http://www.w3.org/2000/09/xmldsig#enveloped-signature",
      "http://www.w3.org/2001/10/xml-exc-c14n#"
    )
  end

  # Java/.NET X500 parsers reject OpenSSL's long attribute names (`organizationIdentifier`), and a
  # seal certificate for a NIP context carries exactly that attribute (2.5.4.97).
  it "renders X509IssuerName in RFC 2253 with OID keys for non-standard attributes" do
    key = OpenSSL::PKey::RSA.new(2048)
    cert = CertificateHelper.self_signed(key, subject: "/C=PL/O=Demo sp. z o.o./CN=Demo/2.5.4.97=VATPL-5555555555")

    doc = Nokogiri::XML(described_class.new(cert: cert, key: key).sign(unsigned_xml))
    issuer = doc.at_xpath("//ds:X509IssuerName", "ds" => Ksef::Xades::Signer::DS_NS).text
    expect(issuer).to eq("OID.2.5.4.97=VATPL-5555555555,CN=Demo,O=Demo sp. z o.o.,C=PL")
  end

  it "escapes RFC 2253 special characters in DN values, leaving '=' alone" do
    key = OpenSSL::PKey::RSA.new(2048)
    cert = CertificateHelper.self_signed(key, subject: "/C=PL/O=Demo, Inc./CN=a+b/OU=x=y")

    doc = Nokogiri::XML(described_class.new(cert: cert, key: key).sign(unsigned_xml))
    issuer = doc.at_xpath("//ds:X509IssuerName", "ds" => Ksef::Xades::Signer::DS_NS).text
    expect(issuer).to eq("OU=x=y,CN=a\\+b,O=Demo\\, Inc.,C=PL")
  end

  it "supports a replaceable external signer (callback)" do
    called = false
    external = lambda { |xml|
      called = true
      "#{xml}<!-- signed -->"
    }
    result = Ksef::Xades::ExternalSigner.wrap(external).sign("<x/>")
    expect(called).to be(true)
    expect(result).to include("signed")
  end

  it "refuses malformed XML and a DOCTYPE instead of repairing and signing them" do
    cert, key = CertificateHelper.rsa_pair
    signer = Ksef::Xades::Signer.new(cert: cert, key: key)

    expect { signer.sign("<AuthTokenRequest><Challenge>x</AuthTokenRequest>") }
      .to raise_error(Ksef::CryptoError, /not well-formed/)
    expect { signer.sign(%(<!DOCTYPE r [<!ENTITY a "x">]><r>&a;</r>)) }.to raise_error(Ksef::CryptoError, /DOCTYPE/)
  end

  it "refuses a key without its private part up front" do
    cert, key = CertificateHelper.ec_pair
    public_only = OpenSSL::PKey.read(key.public_to_der)

    expect { Ksef::Xades::Signer.new(cert: cert, key: public_only) }.to raise_error(Ksef::CryptoError, /private/)
  end

  it "refuses a signer that responds to neither #sign nor #call with a Ksef::ConfigurationError" do
    expect { Ksef::Xades::ExternalSigner.wrap(Object.new) }.to raise_error(Ksef::ConfigurationError)
    expect { Ksef::Xades::ExternalSigner.new(Object.new) }.to raise_error(Ksef::ConfigurationError)
  end

  def signing_certificate(signed_xml)
    doc = Nokogiri::XML(signed_xml)
    ns = { "ds" => Ksef::Xades::Signer::DS_NS, "xades" => Ksef::Xades::Signer::XADES_NS }
    cert = doc.at_xpath("//xades:SigningCertificate/xades:Cert", ns)
    { digest: cert.at_xpath("xades:CertDigest/ds:DigestValue", ns).text,
      serial: cert.at_xpath("xades:IssuerSerial/ds:X509SerialNumber", ns).text,
      issuer: cert.at_xpath("xades:IssuerSerial/ds:X509IssuerName", ns).text }
  end

  it "names the signing certificate by the SHA-256 of its DER and its decimal serial" do
    cert, key = CertificateHelper.rsa_pair

    expect(signing_certificate(described_class.new(cert: cert, key: key).sign(unsigned_xml)))
      .to include(digest: Base64.strict_encode64(Digest::SHA256.digest(cert.to_der)), serial: cert.serial.to_s)
  end

  it "writes streetAddress as STREET, decodes BMPString values and joins a multi-valued RDN with +" do
    key = OpenSSL::PKey::RSA.new(2048)
    name = OpenSSL::X509::Name.new([["C", "PL"], ["street", "Prosta 1"],
                                    ["CN", "Żółć".encode("UTF-16BE").b, OpenSSL::ASN1::BMPSTRING]])
    name.add_entry("O", "Firma", OpenSSL::ASN1::UTF8STRING, loc: 1)
    name.add_entry("OU", "Dział\u0001", OpenSSL::ASN1::UTF8STRING, loc: 1, set: 1)
    cert = CertificateHelper.self_signed(key, subject: name)

    expect(signing_certificate(described_class.new(cert: cert, key: key).sign(unsigned_xml))[:issuer])
      .to eq("CN=Żółć,STREET=Prosta 1,O=Firma+OU=Dział\\01,C=PL")
  end

  it "digests the whole document for URI='', a top-level processing instruction included" do
    cert, key = CertificateHelper.rsa_pair
    with_pi = unsigned_xml.sub("?>", "?>\n<?app hint?>")
    doc = Nokogiri::XML(described_class.new(cert: cert, key: key).sign(with_pi))
    ns = { "ds" => Ksef::Xades::Signer::DS_NS }
    digest = doc.at_xpath("//ds:Reference[@URI='']/ds:DigestValue", ns).text
    doc.at_xpath("//ds:Signature", ns).remove

    expect(digest).to eq(Base64.strict_encode64(Digest::SHA256.digest(doc.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0))))
    expect(doc.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)).to start_with("<?app hint?>")
  end

  it "signs a Nokogiri document as well as a String" do
    cert, key = CertificateHelper.rsa_pair
    document = Ksef::Xades::AuthTokenRequest.new(challenge: "c", context: { nip: "5555555555" }).to_document

    expect(described_class.new(cert: cert, key: key).sign(document)).to include("ds:SignatureValue")
  end

  it "refuses keys KSeF refuses, a certificate that is not one and an Id that is not an NCName" do
    small = OpenSSL::PKey::RSA.new(1024)
    curve = OpenSSL::PKey::EC.generate("secp224r1")
    cert, key = CertificateHelper.rsa_pair

    expect { described_class.new(cert: CertificateHelper.self_signed(small), key: small) }
      .to raise_error(Ksef::CryptoError, /1024 bits; KSeF requires at least 2048/)
    expect { described_class.new(cert: CertificateHelper.self_signed(curve), key: curve) }
      .to raise_error(Ksef::CryptoError, /224 bits/)
    expect { described_class.new(cert: cert.to_pem, key: key) }.to raise_error(Ksef::CryptoError, /cert must be/)
    expect { described_class.new(cert: cert, key: key, signature_id: 'a"b') }
      .to raise_error(Ksef::CryptoError, /NCName/)
  end
end

RSpec.describe Ksef::Crypto::Csr do
  let(:data) do
    { "commonName" => "Jan Kowalski", "givenName" => "Jan", "surname" => "Kowalski", "countryName" => "PL",
      "serialNumber" => "PNOPL-80010112345", "organizationName" => "Firma", "organizationIdentifier" => "VATPL-1",
      "uniqueIdentifier" => "u-1" }
  end

  # A "Decision not to undo": the C# RDN order and ASN.1 types.
  it "writes the subject in the C# RDN order with its ASN.1 string types" do
    csr = OpenSSL::X509::Request.new(Base64.strict_decode64(described_class.generate_ecdsa(data).csr_der_base64))
    rdns = OpenSSL::ASN1.decode(csr.subject.to_der).value.map do |rdn|
      oid, value = rdn.value.first.value
      [oid.oid, value.class]
    end

    expect(rdns).to eq([["2.5.4.3", OpenSSL::ASN1::UTF8String], ["2.5.4.4", OpenSSL::ASN1::UTF8String],
                        ["2.5.4.42", OpenSSL::ASN1::UTF8String], ["2.5.4.10", OpenSSL::ASN1::UTF8String],
                        ["2.5.4.97", OpenSSL::ASN1::UTF8String], ["2.5.4.6", OpenSSL::ASN1::PrintableString],
                        ["2.5.4.5", OpenSSL::ASN1::PrintableString], ["2.5.4.45", OpenSSL::ASN1::UTF8String]])
  end
end

RSpec.describe Ksef::Auth::KsefTokenEncryptor do
  it "encrypts exactly \"token|timestampMs\" for the KsefTokenEncryption key" do
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = Struct.new(:public_key, :public_key_id).new(key.public_key, "kid")
    keys = instance_double(Ksef::Crypto::PublicKeys)
    allow(keys).to receive(:for_usage).with(Ksef::Crypto::PublicKeys::KSEF_TOKEN_ENCRYPTION).and_return(certificate)
    encryptor = described_class.new(crypto: Ksef::Crypto::CryptographyService.new(public_keys: keys), public_keys: keys)

    result = encryptor.encrypt(token: "ab|cd", timestamp_ms: 1_717_500_000_123)
    plaintext = key.decrypt(Base64.strict_decode64(result.encrypted_token),
                            rsa_padding_mode: "oaep", rsa_oaep_md: "sha256", rsa_mgf1_md: "sha256")

    expect([plaintext, result.public_key_id]).to eq(["ab|cd|1717500000123", "kid"])
  end
end
