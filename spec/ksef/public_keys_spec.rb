# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Crypto::PublicKeys do
  let(:connection) { Ksef::Http::Connection.new(config: Ksef::Configuration.new(environment: :test)) }
  subject(:public_keys) { described_class.new(connection: connection) }

  it "fetches, caches and selects a certificate by usage" do
    certs = [
      mf_certificate(usage: "SymmetricKeyEncryption", public_key_id: "sym-1"),
      mf_certificate(usage: "KsefTokenEncryption", public_key_id: "tok-1")
    ]
    stub = stub_public_keys(certs)

    sym = public_keys.for_usage(described_class::SYMMETRIC_KEY_ENCRYPTION)
    tok = public_keys.for_usage(described_class::KSEF_TOKEN_ENCRYPTION)

    expect(sym.public_key_id).to eq("sym-1")
    expect(tok.public_key_id).to eq("tok-1")
    # cache: a single fetch despite multiple reads
    public_keys.for_usage(described_class::SYMMETRIC_KEY_ENCRYPTION)
    expect(stub).to have_been_requested.once
  end

  it "selects the newest valid certificate (max validFrom)" do
    older = mf_certificate(usage: "SymmetricKeyEncryption", public_key_id: "old")
    older["validFrom"] = (Time.now - 100_000).iso8601
    newer = mf_certificate(usage: "SymmetricKeyEncryption", public_key_id: "new")
    newer["validFrom"] = (Time.now - 1_000).iso8601
    stub_public_keys([older, newer])

    expect(public_keys.for_usage(described_class::SYMMETRIC_KEY_ENCRYPTION).public_key_id).to eq("new")
  end

  it "selects RSA certificates only — keys and tokens are wrapped with RSA-OAEP" do
    rsa = mf_certificate(usage: "KsefTokenEncryption", public_key_id: "rsa")
    rsa["validFrom"] = (Time.now - 100_000).iso8601
    ec = mf_certificate(usage: "KsefTokenEncryption", public_key_id: "ec", key: OpenSSL::PKey::EC.generate("prime256v1"))
    stub_public_keys([rsa, ec])

    expect(public_keys.for_usage(described_class::KSEF_TOKEN_ENCRYPTION).public_key_id).to eq("rsa")
  end

  it "refresh! forces a refetch (key rotation)" do
    stub_public_keys([mf_certificate(usage: "SymmetricKeyEncryption")])
    public_keys.all
    public_keys.refresh!
    expect(a_request(:get, "#{ClientHelper::API_BASE}/security/public-key-certificates")).to have_been_made.twice
  end

  it "raises CryptoError when no certificate matches the usage (after one refetch)" do
    stub = stub_public_keys([mf_certificate(usage: "KsefTokenEncryption")])
    expect do
      public_keys.for_usage(described_class::SYMMETRIC_KEY_ENCRYPTION)
    end.to raise_error(Ksef::CryptoError)
    expect(stub).to have_been_requested.twice
  end

  it "refetches once when the cached list has no valid certificate (rotation outlived the cache)" do
    expired = mf_certificate(usage: "SymmetricKeyEncryption", public_key_id: "expired")
    expired["validTo"] = (Time.now - 60).iso8601
    fresh = mf_certificate(usage: "SymmetricKeyEncryption", public_key_id: "fresh")
    stub_request(:get, "#{ClientHelper::API_BASE}/security/public-key-certificates")
      .to_return({ status: 200, body: JSON.generate([expired]) }, { status: 200, body: JSON.generate([fresh]) })

    public_keys.all # warm the cache with the soon-to-be-stale list
    expect(public_keys.for_usage(described_class::SYMMETRIC_KEY_ENCRYPTION).public_key_id).to eq("fresh")
  end
end
