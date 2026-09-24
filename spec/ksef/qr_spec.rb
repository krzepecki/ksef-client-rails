# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Qr::VerificationLink do
  subject(:link) { described_class.new(qr_base_url: "https://qr-test.ksef.mf.gov.pl") }

  let(:invoice_xml) { "<Faktura>1</Faktura>" }
  let(:expected_hash) { Base64.urlsafe_encode64(Digest::SHA256.digest(invoice_xml.b), padding: false) }

  describe "#online (CODE I)" do
    it "builds the link /invoice/{nip}/{DD-MM-YYYY}/{Base64URL hash}" do
      url = link.online(seller_nip: "1111111111", issue_date: Date.new(2026, 2, 1), invoice_xml: invoice_xml)
      expect(url).to eq("https://qr-test.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/#{expected_hash}")
    end

    it "accepts the standard Base64 invoiceHash KSeF returns, written as Base64URL" do
      standard = Base64.strict_encode64(Digest::SHA256.digest(invoice_xml.b))
      url = link.online(seller_nip: "1111111111", issue_date: "01-02-2026", invoice_hash: standard)

      expect(url).to end_with("/#{expected_hash}")
    end

    it "rejects a value that would not stay a single path segment" do
      expect { link.online(seller_nip: "111/../x", issue_date: "01-02-2026", invoice_xml: invoice_xml) }
        .to raise_error(Ksef::ConfigurationError, /seller_nip/)
      expect { link.online(seller_nip: "1111111111", issue_date: "2026/02/01", invoice_xml: invoice_xml) }
        .to raise_error(Ksef::ConfigurationError, /issue_date/)
      expect { link.online(seller_nip: "1111111111", issue_date: "01-02-2026", invoice_hash: "abc?x=1") }
        .to raise_error(Ksef::ConfigurationError, /invoice_hash/)
    end
  end

  it "builds the documented CODE I link (kody-qr.md)" do
    expect(link.online(seller_nip: "1111111111", issue_date: "01-02-2026",
                       invoice_hash: "UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"))
      .to eq("https://qr-test.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE")
  end

  it "decodes the hash: refuses a non-canonical or short one, and one that differs from invoice_xml" do
    ["UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIF", "UtQp9Gpc51y", "!" * 43].each do |hash|
      expect { link.online(seller_nip: "1111111111", issue_date: "01-02-2026", invoice_hash: hash) }
        .to raise_error(Ksef::ConfigurationError, /invoice_hash is not a Base64 SHA-256 digest/)
    end
    expect do
      link.online(seller_nip: "1111111111", issue_date: "01-02-2026", invoice_xml: invoice_xml,
                  invoice_hash: "UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE")
    end.to raise_error(Ksef::ConfigurationError, /does not match/)
  end

  it "refuses a DD-MM-YYYY date that is not in the calendar" do
    %w[30-02-2026 99-99-2026].each do |date|
      expect { link.online(seller_nip: "1111111111", issue_date: date, invoice_xml: invoice_xml) }
        .to raise_error(Ksef::ConfigurationError, /issue_date is not a valid date/)
    end
  end

  describe "issue date" do
    let(:fa3) { File.read(File.expand_path("../../examples/fa3_minimal.xml", __dir__)) } # P_1 2026-02-01

    it "reads P_1 from the invoice, accepts it as YYYY-MM-DD, and refuses a different date" do
      from_xml = link.online(seller_nip: "5555555555", invoice_xml: fa3)

      expect(from_xml).to include("/invoice/5555555555/01-02-2026/")
      expect(link.online(seller_nip: "5555555555", issue_date: "2026-02-01", invoice_xml: fa3)).to eq(from_xml)
      expect(link.online(seller_nip: "5555555555", issue_date: Date.new(2026, 2, 1), invoice_xml: fa3)).to eq(from_xml)
      expect { link.online(seller_nip: "5555555555", issue_date: Date.new(2026, 1, 31), invoice_xml: fa3) }
        .to raise_error(Ksef::ConfigurationError, /31-01-2026 differs from the invoice's P_1 01-02-2026/)
    end

    it "refuses a Time, whose day depends on its zone, and a hash without a date" do
      expect { link.online(seller_nip: "5555555555", issue_date: Time.utc(2026, 1, 31, 23, 30), invoice_xml: fa3) }
        .to raise_error(Ksef::ConfigurationError, /not a Time/)
      expect { link.online(seller_nip: "5555555555", invoice_hash: expected_hash) }
        .to raise_error(Ksef::ConfigurationError, /issue_date is required/)
      expect { link.online(seller_nip: "5555555555", issue_date: "2026-02-30", invoice_hash: expected_hash) }
        .to raise_error(Ksef::ConfigurationError, /not a valid date/)
    end
  end

  describe "NIP arguments" do
    it "normalizes seller_nip and a Nip context_value, and refuses an invalid NIP" do
      url = link.online(seller_nip: "111-111-11-11", issue_date: "01-02-2026", invoice_xml: invoice_xml)
      expect(url).to start_with("https://qr-test.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/")
      expect { link.online(seller_nip: "1234567890", issue_date: "01-02-2026", invoice_xml: invoice_xml) }
        .to raise_error(Ksef::ConfigurationError, /seller_nip is not a valid NIP/)

      key = OpenSSL::PKey::EC.generate("prime256v1")
      offline = link.offline(context_type: "Nip", context_value: "PL1111111111", seller_nip: "111 111 11 11",
                             certificate_serial: "01F20A5D352AE590", private_key: key, invoice_xml: invoice_xml)
      expect(offline).to include("/certificate/Nip/1111111111/1111111111/01F20A5D352AE590/")
    end
  end

  describe "#offline (CODE II)" do
    let(:common_args) do
      { context_type: "Nip", context_value: "1111111111", seller_nip: "1111111111",
        certificate_serial: "01F20A5D352AE590", invoice_xml: invoice_xml }
    end

    # The signed string: the path WITHOUT the https:// prefix and WITHOUT a trailing /.
    def signed_path
      "qr-test.ksef.mf.gov.pl/certificate/Nip/1111111111/1111111111/01F20A5D352AE590/#{expected_hash}"
    end

    it "rejects a certificate serial that is not hex and a context value with reserved characters" do
      key = OpenSSL::PKey::EC.generate("prime256v1")
      expect { link.offline(**common_args, certificate_serial: "01F2/..", private_key: key) }
        .to raise_error(Ksef::ConfigurationError, /certificate_serial/)
      expect { link.offline(**common_args, context_value: "1111111111?x=1", private_key: key) }
        .to raise_error(Ksef::ConfigurationError, /context_value/)
    end

    it "takes the serial as 16 hex digits, an OpenSSL::BN or an Integer, and refuses any other length" do
      key = OpenSSL::PKey::EC.generate("prime256v1")
      ["01f20a5d352ae590", OpenSSL::BN.new("01F20A5D352AE590", 16), 0x01F20A5D352AE590].each do |serial|
        expect(link.offline(**common_args, certificate_serial: serial, private_key: key))
          .to include("/01F20A5D352AE590/")
      end
      %w[1F20A5D352AE590 140164735624437136].each do |serial|
        expect { link.offline(**common_args, certificate_serial: serial, private_key: key) }
          .to raise_error(Ksef::ConfigurationError, /certificate_serial/)
      end
    end

    it "takes the context type as the contract names it or as the authentication API's symbol" do
      key = OpenSSL::PKey::EC.generate("prime256v1")

      expect(link.offline(**common_args, context_type: :nip, context_value: "PL 111-111-11-11", private_key: key))
        .to include("/certificate/Nip/1111111111/")
      expect(link.offline(**common_args, context_type: :internal_id, context_value: "1111111111-00001",
                                         private_key: key)).to include("/certificate/InternalId/1111111111-00001/")
      ["nip", "Regon", :pesel].each do |type|
        expect { link.offline(**common_args, context_type: type, private_key: key) }
          .to raise_error(Ksef::ConfigurationError, /context_type/)
      end
      expect { link.offline(**common_args, context_type: "PeppolId", context_value: "..", private_key: key) }
        .to raise_error(Ksef::ConfigurationError, /context_value/)
    end

    it "refuses a key without its private part, a small RSA key and a curve other than P-256" do
      rsa = OpenSSL::PKey::RSA.new(2048)
      { OpenSSL::PKey.read(rsa.public_to_pem) => /no private part/, OpenSSL::PKey::RSA.new(1024) => /2048/,
        OpenSSL::PKey::EC.generate("secp384r1") => /P-256/ }.each do |key, error|
        expect { link.offline(**common_args, private_key: key) }.to raise_error(Ksef::CryptoError, error)
      end
    end

    # spec/fixtures/qr: the example signature of CIRFMF ksef-docs kody-qr.md, and the test Offline certificate
    # of the official C# SDK's QR tests (KSeF.Client.Tests.Core/E2E/QrCode), whose key made it.
    it "builds the documented link (kody-qr.md), whose signature verifies under the test certificate" do
      doc_hash = "UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"
      doc_path = "qr-test.ksef.mf.gov.pl/certificate/Nip/1111111111/1111111111/01F20A5D352AE590/#{doc_hash}"
      doc_signature = File.read(File.expand_path("../fixtures/qr/code-ii-signature.txt", __dir__)).strip
      certificate = OpenSSL::X509::Certificate.new(
        File.read(File.expand_path("../fixtures/qr/test-offline-certificate.pem", __dir__))
      )
      key = OpenSSL::PKey::RSA.new(2048)
      url = link.offline(**common_args.except(:invoice_xml), invoice_hash: doc_hash, private_key: key)
      base, _, signature = url.rpartition("/")

      expect(base).to eq("https://#{doc_path}")
      expect(key.verify_pss("SHA256", Base64.urlsafe_decode64(signature), doc_path, salt_length: 32,
                                                                                    mgf1_hash: "SHA256")).to be(true)
      expect(certificate.public_key.verify_pss("SHA256", Base64.urlsafe_decode64("#{doc_signature}=="), doc_path,
                                               salt_length: 32, mgf1_hash: "SHA256")).to be(true)
    end

    it "accepts NipVatUe context values with + and * (Irish and Dutch VAT numbers)" do
      key = OpenSSL::PKey::EC.generate("prime256v1")
      %w[1111111111-IE1+12345A 1111111111-IE1*12345A 1111111111-NL1234567+9B01].each do |value|
        url = link.offline(**common_args, context_type: "NipVatUe", context_value: value, private_key: key)
        expect(url).to include("/certificate/NipVatUe/#{value}/")
      end
    end

    it "signs with RSASSA-PSS(SHA-256) — the signature verifies over the path without https://" do
      key = OpenSSL::PKey::RSA.new(2048)
      url = link.offline(**common_args, private_key: key)
      signature = Base64.urlsafe_decode64(url.split("/").last)
      expect(key.verify_pss("SHA256", signature, signed_path, salt_length: 32, mgf1_hash: "SHA256")).to be(true)
    end

    it "signs with ECDSA P-256 as R‖S (64 B) — verifies after conversion to DER" do
      key = OpenSSL::PKey::EC.generate("prime256v1")
      url = link.offline(**common_args, private_key: key)
      signature = Base64.urlsafe_decode64(url.split("/").last)
      expect(signature.bytesize).to eq(64)

      r = OpenSSL::BN.new(signature[0, 32].unpack1("H*"), 16)
      s = OpenSSL::BN.new(signature[32, 32].unpack1("H*"), 16)
      der = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
      expect(key.verify(OpenSSL::Digest.new("SHA256"), der, signed_path)).to be(true)
    end
  end
end

RSpec.describe Ksef::Qr::Code do
  let(:link) { "https://qr-test.ksef.mf.gov.pl/invoice/5555555555/01-02-2026/abc" }

  def view_box(svg) = svg[/viewBox="([^"]+)"/, 1].split.map(&:to_f)

  it "renders a scalable SVG with the 4-module quiet zone (requires rqrcode)" do
    svg = described_class.new(link).as_svg
    # Scalable (viewBox, no fixed size) and with a 4-module quiet zone: 11 px modules → offset 44.
    expect(svg).to start_with("<svg")
    expect(svg).not_to match(/<svg[^>]*\swidth=/)
    expect(svg).to include("translate(44,44)")
    _, _, width, height = view_box(svg)
    expect(width).to eq(height) # no label → a square
    expect(svg).not_to include("<text")
  end

  it "draws the label below the quiet zone, escaped and sized to fit the code's width" do
    label = "5555555555-20250826-0100001AF629-72 & <CERTYFIKAT>"
    svg = described_class.new(link, label: label).as_svg
    doc = Nokogiri::XML(svg, &:strict)
    _, _, width, height = view_box(svg)
    text = doc.at_xpath("//svg:text", "svg" => "http://www.w3.org/2000/svg")

    expect(text.text).to eq(label)
    expect(height).to eq(width + (described_class::LABEL_BAND * 11))
    expect(text["y"].to_f).to be > width # below the code and its quiet zone
    expect(text["font-size"].to_f * described_class::MONOSPACE_ADVANCE * label.length).to be <= width
  end

  it "uses the given colour for the modules and the label" do
    svg = described_class.new(link, label: "OFFLINE").as_svg(color: "1a2b3c")

    expect(svg.scan('fill="#1a2b3c"').size).to eq(2)
    expect(described_class.new(link).as_svg(color: :navy)).to include('fill="navy"')
  end

  it "refuses a colour that is neither hex digits nor a colour name (it goes into SVG attributes)" do
    ['000" onload="alert(1)', "#000", :"red onload", 0].each do |color|
      expect { described_class.new(link).as_svg(color: color) }.to raise_error(Ksef::ConfigurationError, /color/)
    end
  end
end
