# frozen_string_literal: true

require "spec_helper"
require "pp"

# Secrets must never surface through #inspect or `pp` (error pages, the console, exception reports).
RSpec.describe "secret redaction" do
  let(:client) { test_client(access_token: "ACCESS-SECRET") }

  it "Ksef::Client hides the access token" do
    expect(client.inspect).to include("[REDACTED]")
    expect(client.inspect).not_to include("ACCESS-SECRET")
    expect(Ksef::Client.new.inspect).to include("access_token=nil")
  end

  it "Ksef::TokenManager hides both tokens" do
    manager = Ksef::TokenManager.new(client, access_token: "ACCESS-SECRET", refresh_token: "REFRESH-SECRET")
    expect(manager.inspect).to include("[REDACTED]")
    expect(manager.inspect).not_to include("ACCESS-SECRET", "REFRESH-SECRET")
  end

  it "EncryptionData hides the AES key and IV but keeps the public EncryptionInfo" do
    info = Ksef::Crypto::CryptographyService::EncryptionInfo.new(public_key_id: "pk-1")
    data = Ksef::Crypto::CryptographyService::EncryptionData.new(key: "K" * 32, iv: "I" * 16, encryption_info: info)
    expect(data.inspect).to include("pk-1")
    expect(data.inspect).not_to include("K" * 32, "I" * 16)
    expect(data.to_s).to eq(data.inspect)
  end

  it "Auth::Coordinator::Result hides the token pair" do
    result = Ksef::Auth::Coordinator::Result.new(reference_number: "REF-1", access_token: "ACCESS-SECRET",
                                                 refresh_token: "REFRESH-SECRET")
    expect(result.inspect).to include("REF-1")
    expect(result.inspect).not_to include("ACCESS-SECRET", "REFRESH-SECRET")
  end

  it "Csr::Result hides the private key" do
    key = OpenSSL::PKey::EC.generate("prime256v1")
    result = Ksef::Crypto::Csr::Result.new(csr_der_base64: "Q1NS", private_key: key)
    expect(result.inspect).to include("Q1NS", "[REDACTED]")
    expect(result.inspect).not_to include(key.inspect)
  end

  it "the request log and request.ksef keep presigned URLs (sig=), tokens and bodies out" do
    io = StringIO.new
    config = Ksef::Configuration.new(environment: :test).apply(logger: Logger.new(io))
    connection = Ksef::Http::Connection.new(config: config)
    events = []
    stub_const("ActiveSupport::Notifications", Module.new do
      define_singleton_method(:instrument) { |_name, payload, &block| block.call.tap { events << payload.dup } }
    end)
    stub_request(:put, "https://blob.example/part1?sig=SAS-SECRET").to_return(status: 201)
    stub_request(:post, "#{ClientHelper::API_BASE}/auth/token/refresh").to_return(status: 200, body: "{}")

    connection.presigned_transfer("PUT", "https://blob.example/part1?sig=SAS-SECRET", body: "INVOICE-BYTES")
    connection.post("/auth/token/refresh", bearer: "REFRESH-SECRET", json: { "x" => "BODY-SECRET" })

    expect(io.string).to include("PUT presigned -> 201", "POST auth/token/refresh -> 200")
    logged = io.string + events.inspect
    expect(logged).not_to include("SAS-SECRET", "blob.example", "INVOICE-BYTES", "REFRESH-SECRET", "BODY-SECRET")
  end

  # `pp` and IRB (the Rails console) print through #pretty_print, which Struct implements by itself.
  describe "under pp / pretty_inspect" do
    let(:encryption) do
      Ksef::Crypto::CryptographyService::EncryptionData.new(key: "K" * 32, iv: "I" * 16, encryption_info: nil)
    end

    it "keeps the token pair, the AES key and the CSR key redacted" do
      result = Ksef::Auth::Coordinator::Result.new(access_token: "ACCESS-SECRET", refresh_token: "REFRESH-SECRET")
      csr = Ksef::Crypto::Csr::Result.new(csr_der_base64: "Q1NS", private_key: OpenSSL::PKey::EC.generate("prime256v1"))

      expect(result.pretty_inspect).not_to include("ACCESS-SECRET", "REFRESH-SECRET")
      expect(encryption.pretty_inspect).not_to include("K" * 32, "I" * 16)
      expect(csr.pretty_inspect).to include("[REDACTED]")
    end

    it "redacts the objects holding them (client, token manager, an open session)" do
      session = Ksef::Sessions::Online.new(client, reference_number: "S-1", encryption: encryption)
      manager = Ksef::TokenManager.new(client, access_token: "ACCESS-SECRET", refresh_token: "REFRESH-SECRET")

      expect(session.pretty_inspect).to include("S-1")
      expect(session.pretty_inspect).not_to include("K" * 32, "ACCESS-SECRET")
      expect(manager.pretty_inspect).not_to include("ACCESS-SECRET", "REFRESH-SECRET")
    end
  end
end
