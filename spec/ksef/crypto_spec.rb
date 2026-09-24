# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Crypto::CryptographyService do
  subject(:service) { described_class.new(public_keys: nil) }

  describe "#encrypt_aes / #decrypt_aes" do
    let(:key) { OpenSSL::Random.random_bytes(32) }
    let(:iv) { OpenSSL::Random.random_bytes(16) }
    let(:plaintext) { "Faktura <Invoice>ąęś</Invoice>".b }

    it "round-trips AES-256-CBC" do
      ciphertext = service.encrypt_aes(plaintext, key, iv)
      expect(service.decrypt_aes(ciphertext, key, iv)).to eq(plaintext)
    end

    it "produces pure ciphertext WITHOUT an IV prefix" do
      ciphertext = service.encrypt_aes(plaintext, key, iv)
      # If the IV were a prefix, the ciphertext would be 16 B longer than the padded plaintext.
      padded_len = ((plaintext.bytesize / 16) + 1) * 16
      expect(ciphertext.bytesize).to eq(padded_len)
    end

    it "raises Ksef::CryptoError when the data does not decrypt" do
      # A truncated ciphertext always fails (a wrong key passes the padding check 1 time in ~256).
      ciphertext = service.encrypt_aes(plaintext, key, iv)
      expect { service.decrypt_aes(ciphertext.byteslice(0, ciphertext.bytesize - 1), key, iv) }
        .to raise_error(Ksef::CryptoError, /AES decryption failed/)
    end

    it "decrypts using only key+IV (no embedded IV needed)" do
      ciphertext = service.encrypt_aes(plaintext, key, iv)
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      expect(cipher.update(ciphertext) + cipher.final).to eq(plaintext)
    end
  end

  describe "#rsa_oaep_sha256" do
    it "encrypts so an independent RSA private key with OAEP-SHA256 can decrypt" do
      rsa = OpenSSL::PKey::RSA.new(2048)
      data = OpenSSL::Random.random_bytes(32)
      ciphertext = service.rsa_oaep_sha256(rsa.public_key, data)
      decrypted = rsa.decrypt(ciphertext, rsa_padding_mode: "oaep", rsa_oaep_md: "sha256", rsa_mgf1_md: "sha256")
      expect(decrypted).to eq(data)
    end
  end

  describe "#encryption_data / #rewrap" do
    let(:mf_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:public_keys) { Ksef::Crypto::PublicKeys.new(connection: test_client.connection) }
    let(:service) { described_class.new(public_keys: public_keys) }

    before { stub_public_keys([mf_certificate(usage: "SymmetricKeyEncryption", key: mf_key, public_key_id: "sym")]) }

    it "wraps the same key and IV again — only EncryptionInfo changes" do
      data = service.encryption_data
      rewrapped = service.rewrap(data)

      expect([rewrapped.key, rewrapped.iv]).to eq([data.key, data.iv])
      expect(rewrapped.encryption_info.encrypted_symmetric_key).not_to eq(data.encryption_info.encrypted_symmetric_key)
      unwrapped = mf_key.decrypt(Base64.strict_decode64(rewrapped.encryption_info.encrypted_symmetric_key),
                                 rsa_padding_mode: "oaep", rsa_oaep_md: "sha256", rsa_mgf1_md: "sha256")
      expect(unwrapped).to eq(data.key)
    end
  end

  describe "#metadata" do
    it "computes SHA-256 (Base64) and byte size" do
      bytes = "hello".b
      meta = service.metadata(bytes)
      expect(meta.size).to eq(5)
      expect(meta.hash_sha).to eq(Base64.strict_encode64(Digest::SHA256.digest(bytes)))
    end
  end
end
