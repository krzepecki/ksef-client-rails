# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Invoices::Export do
  let(:base) { ClientHelper::API_BASE }
  let(:mf_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:client) { test_client(access_token: "acc") }
  let(:ksef_number) { "5555555555-20250826-0100001AF629-72" }
  let(:metadata_json) { JSON.generate("invoices" => [{ "ksefNumber" => ksef_number, "invoiceNumber" => "FV/1" }]) }
  let(:invoices) { { "#{ksef_number}.xml" => "<Faktura>ąę</Faktura>", "_metadata.json" => metadata_json } }
  let(:zip_bytes) { Ksef::Batch::PackageBuilder.zip(invoices).bytes }

  before { stub_public_keys([mf_certificate(usage: "SymmetricKeyEncryption", key: mf_key)]) }

  def recover_key(encryption_json)
    key = mf_key.decrypt(Base64.strict_decode64(encryption_json["encryptedSymmetricKey"]),
                         rsa_padding_mode: "oaep", rsa_oaep_md: "sha256", rsa_mgf1_md: "sha256")
    [key, Base64.strict_decode64(encryption_json["initializationVector"])]
  end

  # Serves +package_bytes+ as encrypted parts once the export is created; returns the create stub.
  def stub_export(reference, package_bytes, chunks: 2, hash: true)
    stub_request(:post, "#{base}/invoices/exports").to_return do |req|
      key, iv = recover_key(JSON.parse(req.body)["encryption"])
      size = (package_bytes.bytesize / chunks.to_f).ceil
      parts = Array.new(chunks) { |i| package_bytes.byteslice(i * size, size) || "" }.each_with_index.map do |chunk, i|
        ciphertext = client.crypto.encrypt_aes(chunk, key, iv)
        url = "https://blob.example/#{reference}/part#{i + 1}"
        stub_request(:get, url).to_return(status: 200, body: ciphertext)
        part = { "ordinalNumber" => i + 1, "method" => "GET", "url" => url }
        part["encryptedPartHash"] = Base64.strict_encode64(Digest::SHA256.digest(ciphertext)) if hash
        part
      end
      stub_request(:get, "#{base}/invoices/exports/#{reference}").to_return(
        status: 200,
        body: JSON.generate("status" => { "code" => 200 },
                            "package" => { "parts" => parts, "invoiceCount" => 1, "isTruncated" => false })
      )
      { status: 201, body: JSON.generate("referenceNumber" => reference) }
    end
  end

  it "initiates the export, downloads parts, verifies hashes, decrypts and unpacks the package" do
    stub_export("EXP-1", zip_bytes)

    result = described_class.new(client).call(filters: { "subjectType" => "Subject2" }, poll: { interval: 0 })

    expect(result.bytes).to eq(zip_bytes)
    expect(result.compression).to eq(:zip)
    expect(result.entries).to eq(invoices.transform_values(&:b))
    expect(result.metadata).to eq([{ "ksefNumber" => ksef_number, "invoiceNumber" => "FV/1" }])
    expect(result.read("_metadata.json")).to eq(metadata_json.b)
  end

  it "unpacks a TarGz package (compressionType: TarGz)" do
    stub_export("EXP-TGZ", Ksef::Batch::PackageBuilder.tar_gz(invoices).bytes)

    result = described_class.new(client).call(filters: {}, compression_type: "TarGz", poll: { interval: 0 })

    expect(a_request(:post, "#{base}/invoices/exports").with { |r| JSON.parse(r.body)["compressionType"] == "TarGz" })
      .to have_been_made
    expect(result.compression).to eq(:tar_gz)
    expect(result.entries).to eq(invoices.transform_values(&:b))
    expect(result.metadata.first["ksefNumber"]).to eq(ksef_number)
  end

  it "reads entry names without a leading ./ (as tar tools often store them)" do
    dotted = invoices.transform_keys { |name| "./#{name}" }
    result = Ksef::Invoices::Export::Result.new(bytes: Ksef::Batch::PackageBuilder.tar_gz(dotted).bytes, package: {})

    expect(result.entries.keys).to contain_exactly("#{ksef_number}.xml", "_metadata.json")
    expect(result.metadata.first["ksefNumber"]).to eq(ksef_number)
  end

  it "gives entry names as UTF-8, so a non-ASCII name can be read back" do
    files = { "faktura-żółć.xml" => "<F/>" }
    %i[zip tar_gz].each do |format|
      result = Ksef::Invoices::Export::Result.new(bytes: Ksef::Batch::PackageBuilder.public_send(format, files).bytes,
                                                  package: {})

      expect(result.entries.keys).to eq(["faktura-żółć.xml"])
      expect(result.read("faktura-żółć.xml")).to eq("<F/>")
    end
  end

  it "refuses an absolute or climbing entry name and an entry over MAX_ENTRY_SIZE" do
    require "minitar"
    %w[../evil.xml /etc/evil.xml a/../../evil.xml].each do |name|
      zip = Ksef::Batch::PackageBuilder.zip(name.tr("/.", "_~") => "<F/>").bytes.gsub(name.tr("/.", "_~"), name)
      tar = StringIO.new("".b)
      Zlib::GzipWriter.wrap(tar) do |gz|
        Minitar::Writer.open(gz) { |writer| writer.add_file_simple(name, mode: 0o644, size: 4) { |io| io.write("<F/>") } }
      end
      [zip, tar.string].each do |bytes|
        expect { Ksef::Invoices::Export::Result.new(bytes: bytes, package: {}).entries }
          .to raise_error(Ksef::Error, /unexpected file name/)
      end
      expect { Ksef::Batch::PackageBuilder.zip(name => "<F/>") }.to raise_error(Ksef::ConfigurationError, /absolute/)
    end
    stub_const("Ksef::Invoices::Export::MAX_ENTRY_SIZE", 10)
    %i[zip tar_gz].each do |format|
      bytes = Ksef::Batch::PackageBuilder.public_send(format, "big.xml" => "<F>#{'x' * 20}</F>").bytes

      expect { Ksef::Invoices::Export::Result.new(bytes: bytes, package: {}).entries }
        .to raise_error(Ksef::Error, /big.xml in the export package is over 10 bytes/)
    end
  end

  it "keeps the package bytes and part URLs out of #inspect" do
    result = Ksef::Invoices::Export::Result.new(
      bytes: zip_bytes, package: { "invoiceCount" => 1, "parts" => [{ "url" => "https://blob/p?sig=SECRET" }] }
    )

    expect(result.inspect).to include("invoiceCount=1", "parts=1")
    expect([result.inspect, result.to_s, result.pretty_inspect].join).not_to include("SECRET", ksef_number)
    expect(Ksef::Batch::PackageBuilder.zip("a.xml" => "<F>SECRET</F>").inspect).to match(/files=1\z|files=1>/)
  end

  it "streams entries one at a time" do
    result = Ksef::Invoices::Export::Result.new(bytes: zip_bytes, package: {})

    expect(result.each_entry).to be_a(Enumerator)
    expect(result.each_entry.map { |name, _content| name }).to contain_exactly("#{ksef_number}.xml", "_metadata.json")
  end

  it "raises a Ksef::Error for a _metadata.json that is not JSON" do
    bytes = Ksef::Batch::PackageBuilder.zip("_metadata.json" => "{not json").bytes

    expect { Ksef::Invoices::Export::Result.new(bytes: bytes, package: {}).metadata }
      .to raise_error(Ksef::Error, /_metadata.json is not valid JSON/)
  end

  it "checks the format against the status's package.compressionType" do
    declared = ->(type) { Ksef::Invoices::Export::Result.new(bytes: zip_bytes, package: { "compressionType" => type }) }

    expect(declared.call("Zip").compression).to eq(:zip)
    expect { declared.call("TarGz").compression }.to raise_error(Ksef::Error, /zip, the status declares tar_gz/)
  end

  it "treats a package without parts as empty" do
    result = Ksef::Invoices::Export::Result.new(bytes: "".b, package: { "parts" => [] })

    expect(result.compression).to be_nil
    expect(result.entries).to eq({})
    expect(result.metadata).to eq([])
  end

  it "raises CryptoError when the encrypted part hash does not match" do
    stub_request(:post, "#{base}/invoices/exports").to_return do |req|
      key, iv = recover_key(JSON.parse(req.body)["encryption"])
      ciphertext = client.crypto.encrypt_aes(zip_bytes, key, iv)
      stub_request(:get, "https://blob.example/bad").to_return(status: 200, body: ciphertext)
      stub_request(:get, "#{base}/invoices/exports/EXP-2").to_return(
        status: 200,
        body: JSON.generate("status" => { "code" => 200 },
                            "package" => { "parts" => [{ "ordinalNumber" => 1, "method" => "GET",
                                                         "url" => "https://blob.example/bad",
                                                         "encryptedPartHash" => "ZGVmaW5pdGVseV93cm9uZw==" }] })
      )
      { status: 201, body: JSON.generate("referenceNumber" => "EXP-2") }
    end

    expect do
      described_class.new(client).call(filters: {}, poll: { interval: 0 })
    end.to raise_error(Ksef::CryptoError, /part digest mismatch/)
  end

  it "refuses a part that comes without an encryptedPartHash" do
    stub_export("EXP-3", zip_bytes, chunks: 1, hash: false)

    expect { described_class.new(client).call(filters: {}, poll: { interval: 0 }) }
      .to raise_error(Ksef::CryptoError, /no encryptedPartHash/)
  end

  it "retries the export request after a key rotation (21470)" do
    rotation = JSON.generate("exception" => { "exceptionDetailList" => [{ "exceptionCode" => 21_470 }] })
    calls = 0
    stub_request(:post, "#{base}/invoices/exports").to_return do
      calls += 1
      calls == 1 ? { status: 400, body: rotation } : { status: 201, body: JSON.generate("referenceNumber" => "EXP-4") }
    end
    stub_request(:get, "#{base}/invoices/exports/EXP-4").to_return(
      status: 200, body: JSON.generate("status" => { "code" => 200 }, "package" => { "parts" => [] })
    )

    result = described_class.new(client).call(filters: {}, poll: { interval: 0 })

    expect(calls).to eq(2)
    expect(result.entries).to eq({})
  end

  it "rejects an unknown compression type before calling the API" do
    expect { described_class.new(client).call(filters: {}, compression_type: "Rar") }
      .to raise_error(Ksef::ConfigurationError, %r{Zip/TarGz})
    expect(a_request(:post, "#{base}/invoices/exports")).not_to have_been_made
  end
end
