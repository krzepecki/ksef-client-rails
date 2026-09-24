# frozen_string_literal: true

# Oracle generator (Ruby side): exercises the gem's crypto primitives and dumps artifacts
# to a JSON bundle for cross-language verification by verify_crypto.py.
#
# This is the OFFLINE proof for the session cryptography:
#   * AES-256-CBC produces pure ciphertext WITHOUT an IV prefix,
#   * RSA-OAEP uses SHA-256 + MGF1(SHA-256),
#   * the KSeF token is encrypted as "token|timestampMs" with the KsefTokenEncryption key,
#   * CSR subject (RDN order, ASN.1 string types) and signature are well-formed.
#
# Usage: ruby tools/oracle/gen_crypto.rb > bundle.json

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "json"
require "base64"
require "openssl"
require "ksef/errors"
require "ksef/crypto/cryptography_service"
require "ksef/crypto/public_keys"
require "ksef/crypto/csr"
require "ksef/auth/ksef_token_encryptor"

svc = Ksef::Crypto::CryptographyService.new(public_keys: nil)

# --- AES-256-CBC round trip (no IV prefix) ---
key = OpenSSL::Random.random_bytes(32)
iv = OpenSSL::Random.random_bytes(16)
plaintext = "Faktura XML — ąęśćźżół <Invoice>#{'x' * 100}</Invoice>".b
ciphertext = svc.encrypt_aes(plaintext, key, iv)
raise "round-trip mismatch" unless svc.decrypt_aes(ciphertext, key, iv) == plaintext

# --- RSA-OAEP-SHA256: encrypt with a known keypair so Python can decrypt with the private key ---
rsa = OpenSSL::PKey::RSA.new(2048)
sym_key = OpenSSL::Random.random_bytes(32)
rsa_ct = svc.rsa_oaep_sha256(rsa.public_key, sym_key)

# --- KSeF token: Ministry keys stubbed with a known pair, recording the usage the encryptor asks for ---
token_rsa = OpenSSL::PKey::RSA.new(2048)
token_key = Struct.new(:public_key, :public_key_id).new(token_rsa.public_key, "token-key-id")
asked = []
token_keys = Object.new
token_keys.define_singleton_method(:for_usage) { |usage| (asked << usage) && token_key }
token = "20250625-EC-2B7B5D1000-4C2A71E2B5-C3|nip-5265877635|0a1b2c3d4e5f"
timestamp_ms = 1_717_500_000_123 # non-zero milliseconds: seconds or rounding would show
encrypted = Ksef::Auth::KsefTokenEncryptor.new(crypto: svc, public_keys: token_keys)
                                          .encrypt(token: token, timestamp_ms: timestamp_ms)

# --- File metadata (SHA-256 base64 + size) ---
meta = svc.metadata(plaintext)

# --- CSR (RSA + ECDSA) from enrollment data, keys in an order other than the RDN order ---
person = {
  "countryName" => "PL",
  "uniqueIdentifier" => "5555555555",
  "givenName" => "Jan",
  "serialNumber" => "PESEL-90010112345",
  "commonName" => "Jan Kowalski",
  "organizationIdentifier" => "VATPL-5555555555",
  "surname" => "Kowalski",
  "organizationName" => "ACME Sp. z o.o."
}
# A company seal as GET /certificates/enrollments/data returns it: no person fields, diacritics.
seal = {
  "commonName" => "Firma Kowalski Certyfikat",
  "countryName" => "PL",
  "serialNumber" => "ABC123456789",
  "uniqueIdentifier" => "d9d22724-4696-460c-9e5e-b9e3aafb0af3",
  "organizationName" => "Zakład Usług Żółć Sp. z o.o.",
  "organizationIdentifier" => "7762811692",
  "surname" => nil,
  "givenName" => ""
}

bundle = {
  "aes" => {
    "key_b64" => Base64.strict_encode64(key),
    "iv_b64" => Base64.strict_encode64(iv),
    "plaintext_b64" => Base64.strict_encode64(plaintext),
    "ciphertext_b64" => Base64.strict_encode64(ciphertext),
    "ciphertext_len" => ciphertext.bytesize,
    "plaintext_len" => plaintext.bytesize
  },
  "rsa_oaep" => {
    "private_key_pem" => rsa.to_pem,
    "plaintext_b64" => Base64.strict_encode64(sym_key),
    "ciphertext_b64" => Base64.strict_encode64(rsa_ct)
  },
  "ksef_token" => {
    "private_key_pem" => token_rsa.to_pem,
    "token" => token,
    "timestamp_ms" => timestamp_ms,
    "usages_asked" => asked,
    "public_key_id" => encrypted.public_key_id,
    "encrypted_token_b64" => encrypted.encrypted_token
  },
  "metadata" => { "size" => meta.size, "hash_sha_b64" => meta.hash_sha },
  "csrs" => [
    { "label" => "CSR-RSA", "der_b64" => Ksef::Crypto::Csr.generate_rsa(person).csr_der_base64, "subject" => person },
    { "label" => "CSR-EC", "der_b64" => Ksef::Crypto::Csr.generate_ecdsa(person).csr_der_base64, "subject" => person },
    { "label" => "CSR-EC seal", "der_b64" => Ksef::Crypto::Csr.generate_ecdsa(seal).csr_der_base64, "subject" => seal }
  ]
}

puts JSON.generate(bundle)
