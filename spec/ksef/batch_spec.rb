# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Batch pipeline" do
  let(:crypto) { Ksef::Crypto::CryptographyService.new(public_keys: nil) }
  let(:invoices) { { "invoice-1.xml" => "<F>1 ąę</F>", "invoice-2.xml" => "<F>2 óź</F>" } }

  describe Ksef::Batch::PackageBuilder do
    it "builds a ZIP that unpacks back into the original files" do
      package = described_class.zip(invoices)
      entries = {}
      require "zip"
      Zip::InputStream.open(StringIO.new(package.bytes)) do |io|
        while (entry = io.get_next_entry)
          entries[entry.name] = io.read
        end
      end
      expect(entries).to eq(invoices.transform_values(&:b))
      # hash→file map: the hash matches the SHA-256 of the file contents
      expect(package.files["invoice-1.xml"]["fileHash"])
        .to eq(Base64.strict_encode64(Digest::SHA256.digest(invoices["invoice-1.xml"].b)))
    end

    it "builds a tar.gz that the export result unpacks back into the original files" do
      package = described_class.tar_gz(invoices)
      result = Ksef::Invoices::Export::Result.new(bytes: package.bytes, package: {})

      expect(result.compression).to eq(:tar_gz)
      expect(result.entries).to eq(invoices.transform_values(&:b))
    end

    it "flags non-ASCII ZIP entry names as UTF-8 (general-purpose bit 11)" do
      package = described_class.zip({ "faktura-żółć.xml" => "<F/>", "plain.xml" => "<F/>" })
      require "zip"
      flags = Zip::File.open_buffer(StringIO.new(package.bytes)).entries.to_h do |entry|
        [entry.name.dup.force_encoding(Encoding::UTF_8), entry.gp_flags & 0x0800]
      end

      expect(flags).to eq("faktura-żółć.xml" => 0x0800, "plain.xml" => 0)
    end

    it "writes every name as UTF-8 with / for a backslash, keyed the same in the files map" do
      latin2 = "faktura-\xB1.xml".dup.force_encoding("ISO-8859-2")
      package = described_class.zip({ latin2 => "<F/>", :"dir\\b.xml" => "<F/>" })
      require "zip"
      names = Zip::File.open_buffer(StringIO.new(package.bytes)).entries.map { |e| e.name.dup.force_encoding("UTF-8") }

      expect(names).to eq(["faktura-ą.xml", "dir/b.xml"])
      expect(package.files.keys).to eq(names)
      expect(described_class.tar_gz({ "a.xml": "<F/>" }).files.keys).to eq(["a.xml"])
    end

    it "refuses names that collide in the package and an empty package" do
      expect { described_class.zip({ "x.xml" => "<F/>", "x.xml": "<F/>" }) }
        .to raise_error(Ksef::ConfigurationError, /collide/)
      expect { described_class.zip({ "a\\b.xml" => "<F/>", "a/b.xml" => "<F/>" }) }
        .to raise_error(Ksef::ConfigurationError, /collide/)
      expect { described_class.zip([]) }.to raise_error(Ksef::ConfigurationError, /at least one invoice/)
      expect { described_class.tar_gz({}) }.to raise_error(Ksef::ConfigurationError, /at least one invoice/)
    end

    it "refuses a tar entry name over 100 bytes, which the USTAR header cannot hold" do
      name = "Faktura_FV-2026-10-0001_Spółdzielnia Mleczarska Łowicz Spółka z ograniczoną odpowiedzialnością.xml"
      fits = "#{'ż' * 46}.xml" # 96 bytes

      expect(name.bytesize).to eq(106)
      expect { described_class.tar_gz({ "a.xml" => "<F/>", name => "<F/>", "b.xml" => "<F/>" }) }
        .to raise_error(Ksef::ConfigurationError, /limited to 100 bytes: #{name}/)
      package = described_class.tar_gz({ "a.xml" => "<F>1</F>", fits => "<F>2</F>", "b.xml" => "<F>3</F>" })
      entries = Ksef::Invoices::Export::Result.new(bytes: package.bytes, package: {}).entries
      expect(entries.transform_keys { |key| key.dup.force_encoding("UTF-8") })
        .to eq("a.xml" => "<F>1</F>", fits => "<F>2</F>", "b.xml" => "<F>3</F>")
    end
  end

  describe Ksef::Batch::Splitter do
    let(:package) { Ksef::Batch::PackageBuilder.zip(invoices) }
    let(:encryption) { fake_encryption }
    # A small part_size forces a multi-part split.
    let(:splitter) { described_class.new(crypto: crypto, part_size: 64) }

    it "splits into parts; decrypting each SEPARATELY and concatenating restores the original" do
      result = splitter.split(package.bytes, encryption)

      expect(result.parts.size).to be > 1
      expect(result.parts.sum(&:plain_size)).to eq(package.bytes.bytesize)

      # reconstruction "on the export side": decrypt each part separately, concatenate plaintext
      reconstructed = result.parts.sort_by(&:ordinal_number).map do |part|
        crypto.decrypt_aes(splitter.encrypt(package.bytes, part, encryption), encryption.key, encryption.iv)
      end.join
      expect(reconstructed).to eq(package.bytes)
    end

    it "hashes the PLAINTEXT package for batchFile and the ENCRYPTED parts for fileParts" do
      result = splitter.split(package.bytes, encryption)

      expect(result.batch_file["fileHash"])
        .to eq(Base64.strict_encode64(Digest::SHA256.digest(package.bytes)))
      result.parts.each_with_index do |part, index|
        ciphertext = splitter.encrypt(package.bytes, part, encryption)
        expect(result.batch_file["fileParts"][index])
          .to eq("ordinalNumber" => part.ordinal_number, "fileSize" => ciphertext.bytesize,
                 "fileHash" => Base64.strict_encode64(Digest::SHA256.digest(ciphertext)))
      end
    end

    it "keeps no ciphertext — a part is re-encrypted on demand" do
      result = splitter.split(package.bytes, encryption)

      expect(result.parts.first.to_h.keys).to eq(%i[ordinal_number offset plain_size encrypted_size encrypted_hash])
    end

    it "refuses a part size outside 1..100 MB (the contract limit before encryption)" do
      [0, -1, 100_000_001, 1.5, nil].each do |size|
        expect { described_class.new(crypto: crypto, part_size: size) }
          .to raise_error(Ksef::ConfigurationError, /part_size/)
      end
    end
  end

  describe Ksef::Batch::Uploader do
    let(:base) { ClientHelper::API_BASE }
    let(:mf_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:client) { test_client(access_token: "acc") }
    # Large enough for several parts, small enough to stay fast.
    let(:many_invoices) do
      Array.new(4) { |i| ["invoice-#{i}.xml", "<F>#{i} #{Random.bytes(400).unpack1('H*')}</F>"] }.to_h
    end

    before { stub_public_keys([mf_certificate(usage: "SymmetricKeyEncryption", key: mf_key)]) }

    def stub_open(reference, ordinals)
      requests = ordinals.map do |n|
        { "ordinalNumber" => n, "method" => "PUT", "url" => "https://blob.example/#{reference}/#{n}",
          "headers" => { "x-ms-blob-type" => "BlockBlob" } }
      end
      stub_request(:post, "#{base}/sessions/batch").to_return do |request|
        @declared = JSON.parse(request.body)
        { status: 201, body: JSON.generate("referenceNumber" => reference, "partUploadRequests" => requests) }
      end
    end

    it "declares the package format as batchFile.compressionType" do
      %i[zip tar_gz].each_with_index do |compression, index|
        reference = "BATCH-C#{index}"
        stub_open(reference, [1])
        stub_request(:put, "https://blob.example/#{reference}/1").to_return(status: 201, body: "")
        stub_request(:post, "#{base}/sessions/batch/#{reference}/close").to_return(status: 204, body: "")

        described_class.new(client).call(invoices: invoices, compression: compression)
        expect(@declared["batchFile"]["compressionType"]).to eq(compression == :zip ? "Zip" : "TarGz")
      end
    end

    it "declares the session, uploads every part to its presigned URL with its headers, then closes" do
      uploads = {}
      stub_open("BATCH-1", [1, 2, 3])
      stub_request(:put, %r{\Ahttps://blob\.example/BATCH-1/\d\z})
        .with(headers: { "x-ms-blob-type" => "BlockBlob" })
        .to_return do |request|
          uploads[request.uri.path.split("/").last.to_i] = request.body
          { status: 201, body: "" }
        end
      close_stub = stub_request(:post, "#{base}/sessions/batch/BATCH-1/close").to_return(status: 204, body: "")

      part_size = (Ksef::Batch::PackageBuilder.zip(many_invoices).bytes.bytesize / 3.0).ceil
      result = described_class.new(client, part_size: part_size).call(invoices: many_invoices)

      expect(result.reference_number).to eq("BATCH-1")
      expect(result.files.keys).to eq(many_invoices.keys)
      expect(close_stub).to have_been_requested
      # Each uploaded body is exactly the ciphertext declared for its part.
      @declared["batchFile"]["fileParts"].each do |info|
        body = uploads.fetch(info["ordinalNumber"])
        expect(body.bytesize).to eq(info["fileSize"])
        expect(Base64.strict_encode64(Digest::SHA256.digest(body))).to eq(info["fileHash"])
      end
    end

    it "retries the declaration with the same key re-wrapped after a key rotation (21470)" do
      rotation = JSON.generate("exception" => { "exceptionDetailList" => [{ "exceptionCode" => 21_470 }] })
      bodies = []
      stub_request(:post, "#{base}/sessions/batch").to_return do |request|
        bodies << JSON.parse(request.body)
        next { status: 400, body: rotation } if bodies.size == 1

        { status: 201, body: JSON.generate("referenceNumber" => "BATCH-2", "partUploadRequests" => [
                                             { "ordinalNumber" => 1, "url" => "https://blob.example/p1" }
                                           ]) }
      end
      stub_request(:put, "https://blob.example/p1").to_return(status: 201, body: "")
      stub_request(:post, "#{base}/sessions/batch/BATCH-2/close").to_return(status: 204, body: "")

      described_class.new(client).call(invoices: invoices)

      first, second = bodies.map { |body| body["encryption"] }
      expect(second["encryptedSymmetricKey"]).not_to eq(first["encryptedSymmetricKey"])
      expect(recover_key(second)).to eq(recover_key(first)) # same session key → same part hashes
      expect(bodies.map { |body| body["batchFile"] }.uniq.size).to eq(1)
    end

    it "raises BatchUploadError with the session when a part upload fails, and does not close it" do
      stub_open("BATCH-3", [1])
      stub_request(:put, "https://blob.example/BATCH-3/1").to_return(status: 403, body: "<Error>denied</Error>")
      close_stub = stub_request(:post, "#{base}/sessions/batch/BATCH-3/close")

      expect { described_class.new(client).call(invoices: invoices) }
        .to raise_error(Ksef::BatchUploadError) { |error|
          expect(error.reference_number).to eq("BATCH-3")
          expect(error.ordinal_number).to eq(1)
          expect(error.cause).to be_a(Ksef::Forbidden)
        }
      expect(close_stub).not_to have_been_requested
    end

    it "raises BatchUploadError with the session when closing it fails" do
      stub_open("BATCH-5", [1])
      stub_request(:put, "https://blob.example/BATCH-5/1").to_return(status: 201, body: "")
      close_stub = stub_request(:post, "#{base}/sessions/batch/BATCH-5/close").to_return(status: 503, body: "")

      expect { described_class.new(client).call(invoices: invoices) }
        .to raise_error(Ksef::BatchUploadError, /closing the session failed/) { |error|
          expect(error.reference_number).to eq("BATCH-5")
          expect(error.ordinal_number).to be_nil
          expect(error.cause).to be_a(Ksef::ServerError)
        }
      expect(close_stub).to have_been_requested.once # a POST is not retried on 5xx
    end

    it "refuses an empty invoice set before fetching keys or declaring a session" do
      expect { described_class.new(client).call(invoices: {}) }
        .to raise_error(Ksef::ConfigurationError, /at least one invoice/)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "refuses a package of more than 50 parts before declaring a session" do
      open_stub = stub_request(:post, "#{base}/sessions/batch")

      expect { described_class.new(client, part_size: 16).call(invoices: many_invoices) }
        .to raise_error(Ksef::ConfigurationError, /at most 50/)
      expect(open_stub).not_to have_been_requested
    end

    it "refuses upload URLs that do not match the declared parts" do
      stub_open("BATCH-4", [1, 2])

      expect { described_class.new(client).call(invoices: invoices) }
        .to raise_error(Ksef::BatchUploadError, /do not match the declared parts/) { |error|
          expect(error.reference_number).to eq("BATCH-4")
        }
    end

    def recover_key(encryption_json)
      mf_key.decrypt(Base64.strict_decode64(encryption_json["encryptedSymmetricKey"]),
                     rsa_padding_mode: "oaep", rsa_oaep_md: "sha256", rsa_mgf1_md: "sha256")
    end
  end

  def fake_encryption
    Ksef::Crypto::CryptographyService::EncryptionData.new(
      key: OpenSSL::Random.random_bytes(32),
      iv: OpenSSL::Random.random_bytes(16),
      encryption_info: nil
    )
  end
end
