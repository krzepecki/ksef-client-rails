# frozen_string_literal: true

require "stringio"

module Ksef
  module Batch
    # Builds the batch package (ZIP or tar.gz) plus a local hash→file map for correlating statuses.
    # File names stay local — `BatchFilePartInfo` has no `fileName`. A tar entry name must fit the
    # 100-byte USTAR name field: a longer one would need a GNU long-name record, which KSeF is not known to read.
    class PackageBuilder
      # The built package: raw (plaintext) bytes + a name→{hash,size} map of the files inside, keyed by
      # the name in the package.
      Package = Struct.new(:bytes, :files, keyword_init: true) do
        # The package size and file count — never its bytes.
        # @return [String]
        def inspect
          "#<#{self.class.name} bytes=#{bytes.to_s.bytesize} files=#{files.to_h.size}>"
        end
        alias_method :to_s, :inspect

        # `pp` and IRB print through #pretty_print, which Struct implements without calling #inspect.
        def pretty_print(printer)
          printer.text(inspect)
        end
      end

      # Longest tar entry name, in bytes (the USTAR `name` field).
      TAR_NAME_LIMIT = 100

      # ZIP general-purpose flag bit 11 (APPNOTE 4.4.4): the entry name is UTF-8. rubyzip sets it only
      # under the global `Zip.unicode_names`, which would change rubyzip for the whole process.
      UTF8_NAME_FLAG = 0x0800

      # Builds a ZIP package.
      # @param invoices [Hash{String=>String}, Array<String>] invoices (name→XML or a list of XML)
      # @return [Package]
      # @raise [Ksef::ConfigurationError] for no invoices, or two names that are the same in the package
      def self.zip(invoices)
        require "zip"
        named = normalize(invoices)
        buffer = Zip::OutputStream.write_buffer do |zos|
          named.each do |name, xml|
            zos.put_next_entry(zip_entry(name))
            zos.write(xml)
          end
        end
        Package.new(bytes: buffer.string, files: files_map(named))
      end

      # Builds a tar.gz package (requires the `minitar` gem).
      # @param invoices [Hash{String=>String}, Array<String>]
      # @return [Package]
      # @raise [Ksef::ConfigurationError] when minitar is not installed, for no invoices, two names that are
      #   the same in the package, or a name over {TAR_NAME_LIMIT} bytes
      def self.tar_gz(invoices)
        Ksef.require_optional("minitar", "A tar.gz package")
        require "zlib"
        named = normalize(invoices)
        too_long = named.keys.select { |name| name.bytesize > TAR_NAME_LIMIT }
        unless too_long.empty?
          raise ConfigurationError, "tar entry names are limited to #{TAR_NAME_LIMIT} bytes: #{too_long.join(', ')}"
        end

        Package.new(bytes: tar_bytes(named), files: files_map(named))
      end

      def self.tar_bytes(named)
        io = StringIO.new("".b)
        Zlib::GzipWriter.wrap(io) do |gz|
          Minitar::Writer.open(gz) do |tar|
            named.each do |name, xml|
              tar.add_file_simple(name.b, mode: 0o644, size: xml.bytesize) { |stream| stream.write(xml) }
            end
          end
        end
        io.string
      end

      def self.zip_entry(name)
        entry = Zip::Entry.new("", name)
        entry.gp_flags |= UTF8_NAME_FLAG unless name.ascii_only?
        entry
      end

      # Normalizes the input into a name→XML map with the names as they go into the package: UTF-8, with
      # `/` for a backslash (auto-generated names for a list).
      def self.normalize(invoices)
        raise ConfigurationError, "a batch package needs at least one invoice" if invoices.nil? || invoices.empty?
        return invoices.each_with_index.to_h { |xml, i| [format("invoice-%04d.xml", i + 1), xml] } unless
          invoices.is_a?(Hash)

        named = invoices.to_h { |name, xml| [package_name(name), xml] }
        return named if named.size == invoices.size

        duplicates = invoices.keys.group_by { |name| package_name(name) }.select { |_, keys| keys.size > 1 }
        raise ConfigurationError, "invoice names collide in the package: #{duplicates.values.map(&:inspect).join('; ')}"
      end

      def self.package_name(name)
        text = name.to_s
        text = text.encode(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        raise ConfigurationError, "invoice name #{text.inspect} is not valid UTF-8" unless text.valid_encoding?
        raise ConfigurationError, "invoice names must not be blank" if text.strip.empty?

        name = text.tr("\\", "/")
        return name unless name.start_with?("/") || name.split("/").include?("..")

        raise ConfigurationError, "invoice name #{text.inspect} must not be absolute or contain a .. segment"
      rescue EncodingError
        raise ConfigurationError, "invoice name #{name.inspect} cannot be converted to UTF-8"
      end

      def self.files_map(named)
        require "digest"
        require "base64"
        named.transform_values do |xml|
          bytes = xml.b
          { "fileSize" => bytes.bytesize, "fileHash" => Base64.strict_encode64(Digest::SHA256.digest(bytes)) }
        end
      end

      private_class_method :tar_bytes, :zip_entry, :normalize, :package_name, :files_map
    end
  end
end
