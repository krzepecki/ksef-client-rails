# frozen_string_literal: true

require "nokogiri"

# An in-memory model of a form XSD (FA(3) plus its `bazowe/` imports) for the "All fields" tab:
# elements with their documentation and simple types, and model groups (sequence / choice) with
# their own cardinality — flattening them, as `tools/outline_schema.rb` does, would lose that.
class SchemaForm
  # `conditional`: required only once its optional group is used (e.g. P_13_1 + P_14_1).
  Element = Struct.new(:name, :min, :max, :doc, :simple_type, :group, :attributes, :fixed, :conditional,
                       keyword_init: true) do
    def repeated? = max > 1
    def leaf? = group.nil?
  end
  Group = Struct.new(:kind, :min, :max, :items, keyword_init: true) # kind: :sequence | :choice
  Attribute = Struct.new(:name, :fixed, keyword_init: true)
  # base: :date | :datetime | :decimal | :integer | :string; enum: [[value, doc], ...]
  SimpleType = Struct.new(:name, :base, :enum, :max_length, keyword_init: true)

  UNBOUNDED = 1_000_000
  BUILTIN = { "date" => :date, "dateTime" => :datetime, "decimal" => :decimal, "int" => :integer,
              "integer" => :integer, "nonNegativeInteger" => :integer, "positiveInteger" => :integer,
              "byte" => :integer, "gYear" => :integer }.freeze
  MAX_DEPTH = 25

  # @param form_code [String] system code, e.g. "FA (3)"
  # @return [SchemaForm] memoised per form — the XSD does not change at runtime
  def self.for(form_code = Ksef::FormCode::FA3.system_code)
    @cache ||= {}
    @cache[form_code] ||= new(Ksef::Invoices::Validator.schema_path(form_code))
  end

  attr_reader :root

  # @param path [String] the form XSD; its `../bazowe/*.xsd` siblings supply the imported types
  def initialize(path)
    docs = [path, *Dir[File.join(File.dirname(path), "../bazowe/*.xsd")]].map do |file|
      Nokogiri::XML(File.read(file)).tap(&:remove_namespaces!)
    end
    @complex = index(docs, "complexType")
    @simple = index(docs, "simpleType")
    @simple_cache = {}
    @root = build_element(docs.first.at_xpath("/schema/element"), 0)
  end

  private

  # Global named types; the form schema wins over the base files on a name clash.
  def index(docs, kind)
    docs.reverse.each_with_object({}) do |doc, out|
      doc.xpath("/schema/#{kind}[@name]").each { |node| out[node["name"]] = node }
    end
  end

  def build_element(node, depth)
    raise "Schema nesting deeper than #{MAX_DEPTH} at #{node['name']}" if depth > MAX_DEPTH

    element = Element.new(name: node["name"], min: occurs(node["minOccurs"]), max: occurs(node["maxOccurs"]),
                          doc: documentation(node), attributes: [], fixed: node["fixed"])
    complex = node.at_xpath("./complexType") || @complex[local(node["type"])]
    if complex
      fill_complex(element, complex, depth)
    else
      element.simple_type = simple_type(node.at_xpath("./simpleType") || local(node["type"]))
    end
    element
  end

  # complexType: a model group, simpleContent (text + attributes) or complexContent (extension).
  def fill_complex(element, complex, depth)
    if (content = complex.at_xpath("./simpleContent/extension|./simpleContent/restriction"))
      element.simple_type = simple_type(local(content["base"]))
      element.attributes = attributes(content)
    elsif (ext = complex.at_xpath("./complexContent/extension"))
      base = @complex[local(ext["base"])]
      items = [base && model_group(base, depth), model_group(ext, depth)].compact
      element.group = items.size == 1 ? items.first : Group.new(kind: :sequence, min: 1, max: 1, items: items)
      element.attributes = attributes(ext)
    else
      element.group = model_group(complex, depth)
      element.attributes = attributes(complex)
    end
  end

  def model_group(parent, depth)
    node = parent.at_xpath("./sequence|./choice|./all")
    node && build_group(node, depth)
  end

  def build_group(node, depth)
    items = node.element_children.filter_map do |child|
      case child.name
      when "element" then build_element(child, depth + 1)
      when "sequence", "choice", "all" then build_group(child, depth)
      end
    end
    group = Group.new(kind: node.name == "choice" ? :choice : :sequence, min: occurs(node["minOccurs"]),
                      max: occurs(node["maxOccurs"]), items: items)
    items.each { |i| i.conditional = true if i.is_a?(Element) && i.min.positive? } if group.min.zero?
    group
  end

  def attributes(node)
    node.xpath("./attribute").map { |a| Attribute.new(name: a["name"], fixed: a["fixed"] || a["default"]) }
  end

  # Follows restrictions down to an XSD built-in, collecting enumerations and the tightest maxLength.
  def simple_type(ref)
    name = ref.is_a?(String) ? ref : nil
    return @simple_cache[name] if name && @simple_cache.key?(name)

    node = ref.is_a?(String) ? @simple[ref] : ref
    type = SimpleType.new(name: name, base: BUILTIN.fetch(name, :string), enum: [], max_length: nil)
    walk_restrictions(node, type) if node
    @simple_cache[name] = type if name
    type
  end

  def walk_restrictions(node, type, hops = 0)
    restriction = node.at_xpath("./restriction")
    return if restriction.nil? || hops > 10 # a union (e.g. TNrREGON) stays a plain string

    type.enum = restriction.xpath("./enumeration").map { |e| [e["value"], documentation(e)] } if type.enum.empty?
    length = restriction.at_xpath("./maxLength|./length")&.[]("value")&.to_i
    type.max_length = [type.max_length, length].compact.min
    base = local(restriction["base"])
    if BUILTIN.key?(base) then type.base = BUILTIN[base]
    elsif @simple[base] then walk_restrictions(@simple[base], type, hops + 1)
    end
  end

  def documentation(node)
    node.at_xpath("./annotation/documentation")&.text.to_s.gsub(/\s+/, " ").strip
  end

  def occurs(value)
    return 1 if value.nil?

    value == "unbounded" ? UNBOUNDED : value.to_i
  end

  def local(qname)
    qname.to_s.split(":").last
  end
end
