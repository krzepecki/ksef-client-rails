# frozen_string_literal: true

require "base64"
require "digest"

module Ksef
  module Batch
    # Splits the PLAINTEXT package into ≤100 MB parts encrypted with THE SAME session key+IV. A part's
    # ciphertext is therefore deterministic: {#split} only hashes it and {#encrypt} re-creates it at
    # upload time, so a single encrypted part is held in memory at a time.
    class Splitter
      # Largest plaintext part the contract allows (100 MB, decimal as in the SDKs) — also the default.
      MAX_PART_SIZE = 100 * 1000 * 1000
      DEFAULT_PART_SIZE = MAX_PART_SIZE

      # One part: its plaintext byte range plus the size and hash of its ciphertext.
      Part = Struct.new(:ordinal_number, :offset, :plain_size, :encrypted_size, :encrypted_hash,
                        keyword_init: true) do
        # @return [Hash] the `fileParts` entry for the batch session declaration
        def to_part_info
          { "ordinalNumber" => ordinal_number, "fileSize" => encrypted_size, "fileHash" => encrypted_hash }
        end
      end

      # Split result: metadata of the whole package (`batchFile`) + the list of parts.
      Result = Struct.new(:batch_file, :parts, keyword_init: true)

      # @param crypto [Ksef::Crypto::CryptographyService]
      # @param part_size [Integer] maximum plaintext part size, 1..{MAX_PART_SIZE}
      # @raise [Ksef::ConfigurationError] for a part size outside that range
      def initialize(crypto:, part_size: DEFAULT_PART_SIZE)
        unless part_size.is_a?(Integer) && part_size.between?(1, MAX_PART_SIZE)
          raise ConfigurationError, "part_size must be an Integer in 1..#{MAX_PART_SIZE}, got #{part_size.inspect}"
        end

        @crypto = crypto
        @part_size = part_size
      end

      # @param size [Integer] plaintext package size
      # @return [Integer] how many parts {#split} makes of a package that size
      def part_count(size)
        [(size + @part_size - 1) / @part_size, 1].max
      end

      # Splits the package and computes the hash and size of every encrypted part.
      #
      # @param package_bytes [String] plaintext package bytes (ZIP/tar.gz)
      # @param encryption [Ksef::Crypto::CryptographyService::EncryptionData] session key+IV
      # @return [Result]
      def split(package_bytes, encryption)
        plain = binary(package_bytes)
        parts = ranges(plain.bytesize).each_with_index.map do |(offset, plain_size), index|
          meta = @crypto.metadata(encrypt_range(plain, offset, plain_size, encryption))
          Part.new(ordinal_number: index + 1, offset: offset, plain_size: plain_size,
                   encrypted_size: meta.size, encrypted_hash: meta.hash_sha)
        end
        Result.new(batch_file: batch_file_info(plain, parts), parts: parts)
      end

      # The ciphertext of one part — byte for byte what {#split} hashed, given the same key+IV.
      #
      # @param package_bytes [String] the package passed to {#split}
      # @param part [Part]
      # @param encryption [Ksef::Crypto::CryptographyService::EncryptionData]
      # @return [String] ciphertext bytes
      def encrypt(package_bytes, part, encryption)
        encrypt_range(binary(package_bytes), part.offset, part.plain_size, encryption)
      end

      private

      # Avoids copying a package that is already binary (a multi-gigabyte one would double in RAM).
      def binary(bytes)
        bytes.encoding == Encoding::BINARY ? bytes : bytes.b
      end

      def ranges(size)
        return [[0, size]] if size <= @part_size

        (0...size).step(@part_size).map { |offset| [offset, [@part_size, size - offset].min] }
      end

      def encrypt_range(plain, offset, size, encryption)
        @crypto.encrypt_aes(plain.byteslice(offset, size), encryption.key, encryption.iv)
      end

      # `batchFile` = metadata of the PLAINTEXT package + the list of (encrypted) parts.
      def batch_file_info(plain, parts)
        meta = @crypto.metadata(plain)
        {
          "fileSize" => meta.size,
          "fileHash" => meta.hash_sha,
          "fileParts" => parts.map(&:to_part_info)
        }
      end
    end
  end
end
