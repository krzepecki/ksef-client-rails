# frozen_string_literal: true

module Ksef
  module Batch
    # Batch session orchestrator: build package → split and encrypt → declare the session → upload
    # parts sequentially to presigned URLs (`method`+`headers`+`url` from the response; the Java SDK
    # assumes PUT) → close. The contract limits (50 parts, 5 GB) are checked before anything is encrypted.
    class Uploader
      # Most parts a package may have (`batchFile.fileParts`).
      MAX_PARTS = 50
      # Largest plaintext package, in bytes (`batchFile.fileSize`).
      MAX_PACKAGE_SIZE = 5_000_000_000
      # Package format → `batchFile.compressionType` (the API assumes Zip when it is missing).
      COMPRESSION_TYPES = { zip: "Zip", tar_gz: "TarGz" }.freeze

      # Batch upload result: the session to poll, the parts sent and the name→{fileSize, fileHash}
      # map of the invoices inside (to correlate per-invoice statuses).
      Result = Struct.new(:reference_number, :parts, :files, keyword_init: true)

      # @param client [Ksef::Client]
      # @param part_size [Integer] maximum plaintext part size, up to {Splitter::MAX_PART_SIZE}
      # @raise [Ksef::ConfigurationError] for a part size outside 1..{Splitter::MAX_PART_SIZE}
      def initialize(client, part_size: Splitter::DEFAULT_PART_SIZE)
        @client = client
        @splitter = Splitter.new(crypto: client.crypto, part_size: part_size)
      end

      # Runs the full batch upload.
      #
      # @param invoices [Hash{String=>String}, Array<String>] invoice XML
      # @param form_code [Ksef::FormCode, Hash]
      # @param encryption [Ksef::Crypto::CryptographyService::EncryptionData, nil]
      # @param offline_mode [Boolean]
      # @param compression [Symbol] :zip (default) or :tar_gz
      # @return [Result]
      # @raise [Ksef::ConfigurationError] for no invoices, names that collide in the package, a tar entry name
      #   over {PackageBuilder::TAR_NAME_LIMIT} bytes, or a package over the contract limits — before
      #   anything is sent
      # @raise [Ksef::BatchUploadError] when a part cannot be uploaded or the session cannot be closed
      def call(invoices:, form_code: FormCode::FA3, encryption: nil, offline_mode: false, compression: :zip)
        package = build_package(invoices, compression)
        check_limits!(package.bytes.bytesize)
        enc = encryption || @client.crypto.encryption_data
        split = @splitter.split(package.bytes, enc)
        batch_file = split.batch_file.merge("compressionType" => COMPRESSION_TYPES.fetch(compression))

        # After a key rotation (21470) the same key is wrapped under the new certificate, so the
        # parts' ciphertext and hashes stay valid.
        response = @client.public_keys.with_rotation_retry do |retrying|
          enc = @client.crypto.rewrap(enc) if retrying
          @client.batch.open(form_code: form_code, batch_file: batch_file,
                             encryption_info: enc.encryption_info, offline_mode: offline_mode)
        end
        reference_number = response["referenceNumber"]
        upload_parts(reference_number, response["partUploadRequests"], split.parts) do |part|
          @splitter.encrypt(package.bytes, part, enc)
        end
        close_session(reference_number)

        Result.new(reference_number: reference_number, parts: split.parts, files: package.files)
      end

      private

      def build_package(invoices, compression)
        case compression
        when :zip then PackageBuilder.zip(invoices)
        when :tar_gz then PackageBuilder.tar_gz(invoices)
        else raise ConfigurationError, "Unknown compression type: #{compression.inspect} (:zip or :tar_gz)"
        end
      end

      def check_limits!(size)
        if size > MAX_PACKAGE_SIZE
          raise ConfigurationError, "the package has #{size} bytes; KSeF accepts at most #{MAX_PACKAGE_SIZE}"
        end

        parts = @splitter.part_count(size)
        return if parts <= MAX_PARTS

        raise ConfigurationError, "the package needs #{parts} parts; KSeF accepts at most #{MAX_PARTS} " \
                                  "(raise part_size, up to #{Splitter::MAX_PART_SIZE})"
      end

      # Uploads every part to its presigned URL, sequentially; the block returns a part's ciphertext.
      def upload_parts(reference_number, upload_requests, parts)
        requests = Array(upload_requests).to_h { |request| [request["ordinalNumber"], request] }
        declared = parts.map(&:ordinal_number)
        unless requests.size == declared.size && (declared - requests.keys).empty?
          raise BatchUploadError.new("upload URLs do not match the declared parts " \
                                     "(declared #{declared.inspect}, got #{requests.keys.inspect})",
                                     reference_number: reference_number)
        end

        parts.each do |part|
          request = requests.fetch(part.ordinal_number)
          @client.connection.presigned_transfer(request["method"] || "PUT", request["url"],
                                                body: yield(part), headers: request["headers"] || {})
        rescue Error => e
          raise BatchUploadError.new("part #{part.ordinal_number} upload failed: #{e.message}",
                                     reference_number: reference_number, ordinal_number: part.ordinal_number)
        end
      end

      # Close is a POST, so a 5xx or a timeout is not retried — the error keeps the session reference so
      # the caller can check its status and close it again.
      def close_session(reference_number)
        @client.batch.close(reference_number)
      rescue Error => e
        raise BatchUploadError.new("closing the session failed: #{e.message}", reference_number: reference_number)
      end
    end
  end
end
