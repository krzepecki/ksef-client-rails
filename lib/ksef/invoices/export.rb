# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "stringio"

module Ksef
  module Invoices
    # Invoice package export orchestrator: init → polling → download parts from presigned URLs
    # (hash-checked while ENCRYPTED) → decrypt each part separately → a ZIP or tar.gz package.
    # An expired ready package comes back as code `210`, not 410.
    class Export
      # Export status: "finished and ready to download".
      STATUS_COMPLETED = 200
      # Error code for an expired ready package (distinct from 410).
      CODE_PACKAGE_EXPIRED = 210
      # Package compression types (`compressionType`).
      COMPRESSION_TYPES = %w[Zip TarGz].freeze
      # The package file holding `{"invoices": [InvoiceMetadata…]}`; invoices are `{ksefNumber}.xml`.
      METADATA_FILE = "_metadata.json"
      # `package.compressionType` → the format of the decrypted package.
      FORMATS = { "Zip" => :zip, "TarGz" => :tar_gz }.freeze
      # Largest file the package may hold once unpacked, in bytes (`_metadata.json` of 10,000 invoices
      # included); a larger one is refused rather than inflated.
      MAX_ENTRY_SIZE = 100_000_000

      # Export result: the decrypted package bytes + the package description from the status.
      Result = Struct.new(:bytes, :package, keyword_init: true) do
        # The package size and counts — never its bytes or the presigned part URLs.
        # @return [String]
        def inspect
          info = package || {}
          "#<#{self.class.name} bytes=#{bytes.to_s.bytesize} invoiceCount=#{info['invoiceCount'].inspect} " \
            "parts=#{Array(info['parts']).size} isTruncated=#{info['isTruncated'].inspect}>"
        end
        alias_method :to_s, :inspect

        # `pp` and IRB print through #pretty_print, which Struct implements without calling #inspect.
        def pretty_print(printer)
          printer.text(inspect)
        end

        # Read from the leading bytes and checked against the status's `package.compressionType`.
        # @return [Symbol, nil] :zip, :tar_gz, or nil for an empty package
        # @raise [Ksef::Error] for an unknown format, or one other than the status declares
        def compression
          return nil if bytes.empty?

          detected = if bytes.start_with?("\x1F\x8B".b) then :tar_gz
                     elsif bytes.start_with?("PK".b) then :zip
                     else raise Error, "Unrecognized export package format (neither ZIP nor gzip)"
                     end
          declared = FORMATS[(package || {})["compressionType"]]
          return detected if declared.nil? || declared == detected

          raise Error, "Export package is #{detected}, the status declares #{declared}"
        end

        # Streams the package one file at a time (only the current file is held in memory). Names are
        # given without a leading "./", whichever tool built the archive.
        # @yieldparam name [String] file name inside the package — never absolute, never with a ".." segment
        # @yieldparam content [String] file bytes
        # @return [Enumerator, nil] an Enumerator without a block
        # @raise [Ksef::Error] for an absolute or climbing name, a file over {MAX_ENTRY_SIZE}, or a package
        #   that cannot be read
        def each_entry(&block)
          return enum_for(:each_entry) unless block

          case compression
          when :zip then each_zip_entry(&block)
          when :tar_gz then each_tar_entry(&block)
          end
          nil
        end

        # @return [Hash{String=>String}] every file in the package, including `_metadata.json`
        def entries
          each_entry.to_h
        end

        # @return [Array<Hash>] the InvoiceMetadata entries of `_metadata.json` (empty when absent)
        def metadata
          json = read(METADATA_FILE)
          return [] unless json

          data = JSON.parse(json)
          data.is_a?(Array) ? data : Array(data["invoices"])
        rescue JSON::ParserError => e
          raise Error, "#{METADATA_FILE} is not valid JSON: #{e.message}"
        end

        # @param name [String] file name inside the package
        # @return [String, nil] that file's bytes (a ZIP is read through its central directory)
        def read(name)
          if compression == :zip
            entry = zip.find_entry(name) || zip.find_entry("./#{name}")
            return zip.read(entry) if entry
            return nil if name.ascii_only? # a non-ASCII name may be stored without its UTF-8 flag
          end
          each_entry { |entry_name, content| return content if entry_name == name }
          nil
        end

        private

        def zip
          require "zip"
          @zip ||= Zip::File.open_buffer(StringIO.new(bytes))
        end

        def each_zip_entry
          zip.each do |entry|
            next unless entry.file?

            name = entry_name(entry.name)
            content = zip.get_input_stream(entry) { |io| io.read(MAX_ENTRY_SIZE + 1) } || "".b
            yield(name, checked_size(name, content.bytesize) && content)
          end
        rescue Zip::Error => e
          raise Error, "the export package is not a readable ZIP: #{e.message}"
        end

        # Archive names arrive as bytes; KSeF's are ASCII, a batch package's may be UTF-8.
        def entry_name(raw)
          name = raw.dup.force_encoding(Encoding::UTF_8)
          name = (name.valid_encoding? ? name : raw).delete_prefix("./")
          return name unless name.start_with?("/", "\\") || name.split(%r{[/\\]}).include?("..")

          raise Error, "unexpected file name in the export package: #{name.inspect}"
        end

        def checked_size(name, size)
          return true if size <= MAX_ENTRY_SIZE

          raise Error, "#{name} in the export package is over #{MAX_ENTRY_SIZE} bytes"
        end

        def each_tar_entry
          Ksef.require_optional("minitar", "Unpacking a tar.gz package")
          require "zlib"
          Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gz|
            Minitar::Reader.open(gz) do |tar|
              tar.each_entry do |entry|
                next unless entry.file?

                name = entry_name(entry.full_name)
                checked_size(name, entry.size)
                # GzipReader yields binary data; an empty file reads as nil.
                yield(name, entry.read || "".b)
              end
            end
          end
        rescue Zlib::Error => e
          raise Error, "the export package is not a readable tar.gz: #{e.message}"
        end
      end

      # @param client [Ksef::Client]
      def initialize(client)
        @client = client
      end

      # Runs the full export and returns the assembled package.
      #
      # @param filters [Hash] query filters
      # @param only_metadata [Boolean] the package then holds `_metadata.json` alone
      # @param compression_type [String, nil] "Zip" or "TarGz" (tar.gz needs the `minitar` gem to unpack);
      #   nil leaves it to the API (Zip)
      # @param poll [Hash] polling options
      # @return [Result]
      def call(filters:, only_metadata: false, compression_type: "Zip", poll: {})
        unless compression_type.nil? || COMPRESSION_TYPES.include?(compression_type)
          raise ConfigurationError, "compression_type must be one of #{COMPRESSION_TYPES.join('/')}"
        end

        encryption = @client.crypto.encryption_data
        init = @client.public_keys.with_rotation_retry do |retrying|
          encryption = @client.crypto.rewrap(encryption) if retrying
          @client.exports.create(encryption_info: encryption.encryption_info, filters: filters,
                                 only_metadata: only_metadata, compression_type: compression_type)
        end
        status = wait_for_package(init["referenceNumber"], poll)
        package = status["package"]
        Result.new(bytes: assemble(package, encryption), package: package)
      end

      private

      def wait_for_package(reference_number, poll)
        Polling.run(description: "export #{reference_number}", logger: @client.config.logger, **poll) do
          response = @client.exports.status(reference_number)
          interpret_status(response)
        end
      end

      def interpret_status(response)
        status = response["status"] || {}
        case status["code"]
        when STATUS_COMPLETED
          response["package"] ? response : Polling.pending
        when CODE_PACKAGE_EXPIRED
          raise Gone.new("Export package expired", codes: [CODE_PACKAGE_EXPIRED], body: response)
        when nil, 100, 150
          Polling.pending
        else
          raise ApiError.new(status["description"] || "Export error", codes: [status["code"]].compact, body: response)
        end
      end

      # Downloads parts in order, verifies each ciphertext hash, decrypts each part separately and
      # appends the plaintext to one buffer (no second copy of the package).
      def assemble(package, encryption)
        parts = Array(package["parts"]).sort_by { |p| p["ordinalNumber"] }
        parts.each_with_object(String.new(encoding: Encoding::BINARY)) do |part, buffer|
          buffer << download_and_decrypt(part, encryption)
        end
      end

      def download_and_decrypt(part, encryption)
        method = part["method"] || "GET"
        response = @client.connection.presigned_transfer(method, part["url"])
        verify_encrypted_part!(response.raw_body, part)
        @client.crypto.decrypt_aes(response.raw_body, encryption.key, encryption.iv)
      end

      # Verifies the integrity of the ENCRYPTED part: SHA-256 of the downloaded bytes ==
      # encryptedPartHash. A part without a hash is refused rather than trusted.
      def verify_encrypted_part!(bytes, part)
        expected = part["encryptedPartHash"].to_s
        raise CryptoError, "Export part #{part['ordinalNumber']} has no encryptedPartHash" if expected.empty?

        actual = Base64.strict_encode64(Digest::SHA256.digest(bytes))
        return if actual == expected

        raise CryptoError,
              "Export part digest mismatch #{part['ordinalNumber']}: expected #{expected}, got #{actual}"
      end
    end
  end
end
