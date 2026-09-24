# frozen_string_literal: true

require "nokogiri"

module Ksef
  module Invoices
    # The element tree of a packaged form schema — the fields an invoice may carry, with cardinality
    # and type ({Validator#outline}). The schemas are large, so it renders a subtree to a given depth.
    # @api private
    class SchemaOutline
      # @param schema_path [String] packaged XSD file
      def initialize(schema_path)
        @doc = Nokogiri::XML(File.read(schema_path))
        @doc.remove_namespaces!
        @types = @doc.xpath("/schema/complexType").to_h { |node| [node["name"], node] }
      end

      # @param path [String] slash-separated element path, e.g. "Faktura/Fa/Adnotacje"
      # @param depth [Integer] levels below +path+
      # @param descriptions [Boolean] add each element's description from the schema on its own line
      # @return [String] one line per element: name (indented), cardinality, type
      # @raise [Ksef::ConfigurationError] when the path does not exist in the schema
      def render(path, depth, descriptions: false)
        @descriptions = descriptions
        lines = []
        walk(resolve(path), depth, "", lines)
        lines.join("\n")
      end

      private

      def walk(element, depth, indent, lines)
        type = complex_type(element)
        return if type.nil? || depth.zero?

        group_elements(type).each do |child, occurrence, branch|
          note = cardinality(child, occurrence) + (branch ? " | #{branch}" : "")
          lines << format("%<name>-44s %<note>-20s %<type>s",
                          name: indent + child["name"], note: note, type: child["type"].to_s.split(":").last).rstrip
          text = @descriptions && description(child)
          lines << "#{indent}  — #{text}" if text
          walk(child, depth - 1, "#{indent}  ", lines)
        end
      end

      # The element's `xsd:documentation`, or its named type's, on one line.
      def description(element)
        node = element.at_xpath("./annotation/documentation") ||
               @types[element["type"].to_s.split(":").last]&.at_xpath("./annotation/documentation")
        text = node&.text.to_s.gsub(/\s+/, " ").strip
        text.empty? ? nil : text
      end

      # The complexType behind an element: inline, or looked up by its type name.
      def complex_type(element)
        element.at_xpath("./complexType") || @types[element["type"].to_s.split(":").last]
      end

      # Elements of a model group with the occurrence of their enclosing groups (an optional or repeated
      # sequence/choice makes its elements so) and their choice branch: "choice" for a single-element
      # branch, "choice: A+B" for a sequence one. An extension starts with its base type's elements.
      def group_elements(node, occurrence = { optional: false, max: nil }, branch = nil, out = [])
        node.element_children.each do |child|
          case child.name
          when "element" then out << [child, occurrence, branch]
          when "sequence", "all" then group_elements(child, within(child, occurrence), branch, out)
          when "complexContent", "restriction" then group_elements(child, occurrence, branch, out)
          when "extension"
            base = @types[child["base"].to_s.split(":").last]
            group_elements(base, occurrence, branch, out) if base
            group_elements(child, occurrence, branch, out)
          when "choice" then choice_elements(child, within(child, occurrence), out)
          end
        end
        out
      end

      def choice_elements(choice, occurrence, out)
        choice.element_children.each do |alternative|
          names = alternative.name == "element" ? [] : group_elements(alternative).map { |element, *| element["name"] }
          label = names.size > 1 ? "choice: #{names.join('+')}" : "choice"
          case alternative.name
          when "element" then out << [alternative, occurrence, label]
          when "choice" then choice_elements(alternative, within(alternative, occurrence), out)
          else group_elements(alternative, within(alternative, occurrence), label, out)
          end
        end
      end

      def within(group, occurrence)
        max = group["maxOccurs"]
        { optional: occurrence[:optional] || group["minOccurs"] == "0",
          max: occurrence[:max] || (max && max != "1" ? max : nil) }
      end

      def cardinality(element, occurrence)
        min = occurrence[:optional] ? "0" : element["minOccurs"] || "1"
        max = element["maxOccurs"] || "1"
        max = occurrence[:max] if max == "1" && occurrence[:max]
        return "required" if [min, max] == %w[1 1]
        return "optional" if min == "0" && max == "1"

        "#{min}..#{max}"
      end

      def resolve(path)
        names = path.to_s.split("/")
        node = @doc.xpath("/schema/element").find { |element| element["name"] == names.first }
        raise ConfigurationError, "No top-level element #{names.first.inspect} in the schema" unless node

        names.drop(1).each do |name|
          type = complex_type(node)
          node = type && group_elements(type).map(&:first).find { |element| element["name"] == name }
          raise ConfigurationError, "#{name} not found under #{path}" unless node
        end
        node
      end
    end
  end
end
