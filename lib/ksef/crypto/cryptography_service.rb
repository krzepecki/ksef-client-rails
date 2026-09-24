# frozen_string_literal: true

require "openssl"
require "base64"
require "digest"

module Ksef
  module Crypto
    # Session cryptography: AES-256-CBC/PKCS#7 with a 16-byte IV, the symmetric key
    # wrapped with RSA-OAEP SHA-256 + MGF1(SHA-256), hashes SHA-256 in Base64.
    #
    # The payload is PLAIN ciphertext WITHOUT an IV prefix — the IV travels only in
    # EncryptionInfo. Some documentation suggests a prefix; both SDKs send none and the gem follows them.
    class CryptographyService
      # Encryption material for one session: key+IV (in the clear) plus {EncryptionInfo} to send.
      EncryptionData = Struct.new(:key, :iv, :encryption_info, keyword_init: true) do
        # The session key never goes to error pages, `pp` output or exception reports.
        # @return [String]
        def inspect
          "#<#{self.class.name} key=[REDACTED] iv=[REDACTED] encryption_info=#{encryption_info.inspect}>"
        end
        alias_method :to_s, :inspect

        # `pp` and IRB print through #pretty_print, which Struct implements without calling #inspect.
        def pretty_print(printer)
          printer.text(inspect)
        end
      end

      # Encryption data sent to the API (camelCase fields in JSON).
      EncryptionInfo = Struct.new(:encrypted_symmetric_key, :initialization_vector, :public_key_id,
                                  keyword_init: true) do
        # @return [Hash] JSON representation matching the API contract
        def to_h
          {
            "encryptedSymmetricKey" => encrypted_symmetric_key,
            "initializationVector" => initialization_vector,
            "publicKeyId" => public_key_id
          }.compact
        end
      end

      # Digest and size of a file/chunk (hash in Base64).
      FileMetadata = Struct.new(:size, :hash_sha, keyword_init: true) do
        # @return [Hash] { "fileSize" => Integer, "fileHash" => Base64 }
        def to_h
          { "fileSize" => size, "fileHash" => hash_sha }
        end
      end

      # @param public_keys [Ksef::Crypto::PublicKeys]
      def initialize(public_keys:)
        @public_keys = public_keys
      end

      # Session material: a random 256-bit key + 16-byte IV (unless given), the key wrapped under the
      # current usage=SymmetricKeyEncryption certificate.
      # @param key [String, nil] 32 B; generated when nil
      # @param iv [String, nil] 16 B; generated when nil
      # @return [EncryptionData]
      def encryption_data(key: nil, iv: nil)
        key ||= OpenSSL::Random.random_bytes(32)
        iv ||= OpenSSL::Random.random_bytes(16)
        cert = @public_keys.for_usage(PublicKeys::SYMMETRIC_KEY_ENCRYPTION)
        encrypted_key = rsa_oaep_sha256(cert.public_key, key)

        info = EncryptionInfo.new(
          encrypted_symmetric_key: Base64.strict_encode64(encrypted_key),
          initialization_vector: Base64.strict_encode64(iv),
          public_key_id: cert.public_key_id
        )
        EncryptionData.new(key: key, iv: iv, encryption_info: info)
      end

      # The same key and IV wrapped again under the current certificate — after a key rotation
      # (21470) only EncryptionInfo changes, so data already encrypted with the key stays valid.
      # @param data [EncryptionData]
      # @return [EncryptionData]
      def rewrap(data)
        encryption_data(key: data.key, iv: data.iv)
      end

      # Encrypts bytes with AES-256-CBC/PKCS7. Returns PLAIN ciphertext without an IV prefix.
      # @param content [String] plaintext bytes
      # @param key [String] 32 B
      # @param iv [String] 16 B
      # @return [String] ciphertext (bytes)
      def encrypt_aes(content, key, iv)
        cipher = OpenSSL::Cipher.new("aes-256-cbc")
        cipher.encrypt
        cipher.key = key
        cipher.iv = iv
        cipher.update(content) << cipher.final # appended in place: a part is up to 100 MB
      end

      # Decrypts AES-256-CBC/PKCS7 bytes (ciphertext without an IV prefix; IV from EncryptionInfo).
      # @param content [String] ciphertext
      # @param key [String] 32 B
      # @param iv [String] 16 B
      # @return [String] plaintext bytes
      # @raise [Ksef::CryptoError] when the data does not decrypt (wrong key/IV or corrupted bytes)
      def decrypt_aes(content, key, iv)
        cipher = OpenSSL::Cipher.new("aes-256-cbc")
        cipher.decrypt
        cipher.key = key
        cipher.iv = iv
        cipher.update(content) << cipher.final
      rescue OpenSSL::Cipher::CipherError => e
        raise CryptoError, "AES decryption failed: #{e.message}"
      end

      # Encrypts data with RSA-OAEP using SHA-256 and MGF1(SHA-256).
      # @param public_key [OpenSSL::PKey::RSA]
      # @param data [String]
      # @return [String] ciphertext (bytes)
      def rsa_oaep_sha256(public_key, data)
        public_key.encrypt(
          data,
          rsa_padding_mode: "oaep",
          rsa_oaep_md: "sha256",
          rsa_mgf1_md: "sha256"
        )
      end

      # Computes the SHA-256 digest (Base64) and the byte size.
      # @param bytes [String]
      # @return [FileMetadata]
      def metadata(bytes)
        FileMetadata.new(
          size: bytes.bytesize,
          hash_sha: Base64.strict_encode64(Digest::SHA256.digest(bytes))
        )
      end
    end
  end
end
