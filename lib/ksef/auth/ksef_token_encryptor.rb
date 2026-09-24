# frozen_string_literal: true

require "base64"

module Ksef
  module Auth
    # Encrypts the KSeF token for token authentication: `"#{token}|#{timestampMs}"`
    # wrapped with RSA-OAEP(SHA-256), Base64. The timestamp must come from `/auth/challenge`
    # (epoch MILLISECONDS), never the local clock. ECIES is out of scope: undocumented in the API
    # docs and assembled incompatibly between the two SDKs.
    class KsefTokenEncryptor
      # @param crypto [Ksef::Crypto::CryptographyService]
      # @param public_keys [Ksef::Crypto::PublicKeys]
      def initialize(crypto:, public_keys:)
        @crypto = crypto
        @public_keys = public_keys
      end

      # Encryption result: Base64 token + public key identifier.
      Result = Struct.new(:encrypted_token, :public_key_id, keyword_init: true)

      # @param token [String] KSeF token (secret)
      # @param timestamp_ms [Integer] timestampMs from /auth/challenge
      # @return [Result]
      def encrypt(token:, timestamp_ms:)
        cert = @public_keys.for_usage(Crypto::PublicKeys::KSEF_TOKEN_ENCRYPTION)
        payload = "#{token}|#{timestamp_ms}"
        ciphertext = @crypto.rsa_oaep_sha256(cert.public_key, payload)
        Result.new(
          encrypted_token: Base64.strict_encode64(ciphertext),
          public_key_id: cert.public_key_id
        )
      end
    end
  end
end
