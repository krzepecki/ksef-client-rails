# frozen_string_literal: true

require "nokogiri"

module Ksef
  module Invoices
    # Validates an invoice locally against the form XSD KSeF applies, plus KSeF's XML rules (UTF-8 without
    # a BOM, no processing instructions, no discouraged characters): what fails here fails on KSeF too, in
    # libxml2's wording rather than KSeF's. Schemas ship with the gem (FA(2), FA(3), FA_RR(1)); not PEF (UBL).
    class Validator
      # Directory holding the schemas packaged with the gem.
      SCHEMA_ROOT = File.expand_path("../../../schemas", __dir__)

      # Form `systemCode` → schema file. The version lives in the file name, so a new
      # `schemaVersion` means replacing the file plus the FormCode constant (schemas/README.md).
      SCHEMAS = {
        "FA (2)" => "FA/schemat_FA(2)_v1-0E.xsd",
        "FA (3)" => "FA/schemat_FA(3)_v1-0E.xsd",
        "FA_RR (1)" => "RR/schemat_FA_RR(1)_v1-1E.xsd"
      }.freeze

      # Code points KSeF refuses anywhere in an invoice (beyond what XML 1.0 itself forbids): C1 controls
      # except U+0085, and the Unicode noncharacters.
      DISALLOWED_CHARACTERS = Regexp.new(
        "[\\u007F-\\u0084\\u0086-\\u009F\\uFDD0-\\uFDEF" \
        "#{(0..16).map { |plane| format('\\u{%<p>XFFFE}\\u{%<p>XFFFF}', p: plane) }.join}]"
      )

      # One violation: `path` names the element (e.g. "Faktura/Podmiot2/DaneIdentyfikacyjne/NIP"), nil for
      # a document that is not well-formed and for KSeF's document-level rules.
      Issue = Struct.new(:path, :line, :message, keyword_init: true)

      @schemas = {}
      @schemas_lock = Mutex.new

      # @return [String] systemCode of the form this instance validates against
      attr_reader :system_code

      # @param form_code [Ksef::FormCode, String] invoice form (object or systemCode)
      # @raise [Ksef::ConfigurationError] when no packaged schema exists for the form
      def initialize(form_code: FormCode::FA3)
        @system_code = form_code.respond_to?(:system_code) ? form_code.system_code : form_code.to_s
        @schema = self.class.schema(@system_code)
      end

      # Path to the schema for the given `systemCode`.
      #
      # @param system_code [String]
      # @return [String]
      # @raise [Ksef::ConfigurationError]
      def self.schema_path(system_code)
        relative = SCHEMAS[system_code]
        if relative.nil?
          raise ConfigurationError, "no packaged schema for form #{system_code.inspect} " \
                                    "(available: #{SCHEMAS.keys.join(', ')})"
        end

        File.join(SCHEMA_ROOT, relative)
      end

      # The parsed schema, loaded once per process — parsing the XSD set costs far more than a
      # validation, and a parsed schema is safe to share between threads.
      #
      # The schema is loaded as a document WITH the file URL — without it the relative
      # `../bazowe/...` import has nothing to resolve against and libxml tries to fetch the schema
      # over the network (which it refuses: "Attempt to load network entity").
      #
      # @param system_code [String]
      # @return [Nokogiri::XML::Schema]
      # @raise [Ksef::ConfigurationError]
      def self.schema(system_code)
        @schemas_lock.synchronize do
          @schemas[system_code] ||= begin
            path = schema_path(system_code)
            Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(path), path))
          end
        end
      end

      # Validates the invoice and returns the validator messages — a document that is not well-formed
      # XML yields its parse error instead.
      #
      # @param xml [String] invoice XML
      # @return [Array<String>] empty when the invoice matches the schema and KSeF's XML rules
      def validate(xml)
        errors(xml).map(&:message)
      end

      # Like {#validate}, with the element path and line of each violation — e.g. to show it next to a
      # form field.
      #
      # @param xml [String] invoice XML
      # @return [Array<Issue>] empty when the invoice matches the schema and KSeF's XML rules
      def errors(xml)
        rules = document_issues(xml.to_s)
        doc = parse(xml)
        namespace = doc.errors.select { |error| error.error? || error.fatal? }.map { |error| issue(error, nil) }
        return rules + namespace unless namespace.empty?

        rules + processing_instructions(doc) + @schema.validate(doc).map { |error| issue(error, doc) }
      rescue Nokogiri::XML::SyntaxError => e
        rules + [issue(e, nil)]
      end

      # The form's field tree — what an invoice may carry, with cardinality and type.
      #
      # @param path [String] slash-separated element path, e.g. "Faktura/Fa/Adnotacje"
      # @param depth [Integer, nil] levels to show; nil — 2 for "Faktura", the whole subtree otherwise
      # @param descriptions [Boolean] add each element's description from the schema (Polish) below it
      # @return [String] one line per element: name (indented by depth), cardinality, type
      # @raise [Ksef::ConfigurationError] when the path does not exist in the schema
      def outline(path = "Faktura", depth: nil, descriptions: false)
        depth ||= path == "Faktura" ? 2 : 99
        SchemaOutline.new(self.class.schema_path(system_code)).render(path, depth, descriptions: descriptions)
      end

      # @param xml [String]
      # @return [Boolean] whether the invoice matches the schema
      def valid?(xml)
        validate(xml).empty?
      end

      # Validates and raises when the invoice does not match.
      #
      # @param xml [String]
      # @return [true]
      # @raise [Ksef::SchemaValidationError]
      def validate!(xml)
        issues = errors(xml)
        return true if issues.empty?

        raise SchemaValidationError.new("invoice does not match schema #{system_code}",
                                        messages: issues.map(&:message), errors: issues, system_code: system_code)
      end

      private

      # KSeF's checks of the document itself (faktury/weryfikacja-faktury.md), before its schema.
      def document_issues(xml)
        bytes = xml.b
        issues = []
        issues << rule("the document starts with a byte order mark; KSeF requires UTF-8 without one") if
          bytes.start_with?("\xEF\xBB\xBF".b)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        # UTF-16 text is valid UTF-8 byte for byte only as long as it holds NULs, which XML never may.
        return issues << rule("the document is not valid UTF-8") if !text.valid_encoding? || text.include?("\0")

        declaration = text[/\A\uFEFF?<\?xml\s[^>]*\?>/].to_s
        encoding = declaration[/encoding\s*=\s*["']([^"']+)["']/, 1]
        issues << rule("the XML declaration names encoding #{encoding}; KSeF requires UTF-8") if
          encoding && !encoding.casecmp?("UTF-8")
        version = declaration[/version\s*=\s*["']([^"']+)["']/, 1]
        issues << rule("the document declares XML #{version}; KSeF requires XML 1.0") if version && version != "1.0"
        bad = text[DISALLOWED_CHARACTERS]
        issues << rule("the document contains #{format('U+%04X', bad.ord)}, a character KSeF refuses") if bad
        issues
      end

      def processing_instructions(doc)
        doc.xpath("//processing-instruction()").map do |node|
          Issue.new(path: nil, line: node.line, message: "processing instruction <?#{node.name}?>: KSeF refuses them")
        end
      end

      def rule(message)
        Issue.new(path: nil, line: nil, message: message)
      end

      def issue(error, doc)
        Issue.new(path: element_path(error, doc), line: error.line, message: error.message.strip)
      end

      # libxml2 reports a positional path ("/*/*[3]/*[1]", "/*/f:P_2"); this walks it step by step by
      # local name and position — the prefixes need not be declared on the root — and names each step.
      def element_path(error, doc)
        xpath = error.respond_to?(:path) ? error.path : nil
        return nil if doc.nil? || xpath.nil? || !xpath.start_with?("/")

        node = xpath.delete_prefix("/").split("/").inject(doc) { |parent, step| parent && child_at(parent, step) }
        return nil unless node.is_a?(Nokogiri::XML::Element)

        [*node.ancestors.reverse.grep(Nokogiri::XML::Element), node].map(&:name).join("/")
      end

      def child_at(parent, step)
        name, index = step.match(/\A(?:[^:\[]+:)?([^\[]+)(?:\[(\d+)\])?\z/)&.captures
        return nil unless name

        candidates = parent.element_children.select { |child| name == "*" || child.name == name }
        candidates[(index || "1").to_i - 1]
      end

      # Strict, so that a document KSeF would reject as malformed fails here too (the default RECOVER
      # mode silently repairs it); no network access, no entity expansion.
      def parse(xml)
        Nokogiri::XML(xml) { |config| config.strict.nonet }
      end
    end
  end
end
