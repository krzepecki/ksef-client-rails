# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

# The KSeF OpenAPI document the gem targets (spec/fixtures/openapi/) and a validator for the subset of
# OpenAPI 3.0 schema keywords that document uses ($ref, allOf/oneOf/anyOf, type, required, properties,
# items, enum, nullable, length/pattern/range limits, the date-time/date/byte/int32/int64 formats).
module OpenapiContract
  SPEC_FILE = File.expand_path("../fixtures/openapi/ksef-api-#{Ksef::API_VERSION}.json", __dir__)
  VERBS = %w[get post put delete].freeze

  # One operation of the document.
  Operation = Struct.new(:verb, :template, :definition, :pattern, keyword_init: true) do
    def key
      "#{verb.upcase} #{template}"
    end

    def parameters(location)
      Array(definition["parameters"]).select { |parameter| parameter["in"] == location }
    end

    # @return [Hash{String=>String}] the decoded path parameters of a path the template matches
    def path_values(path)
      match = pattern.match(path)
      match ? match.named_captures.transform_values { |value| URI.decode_uri_component(value) } : {}
    end

    def anonymous?
      Array(definition["security"]).empty?
    end

    def request_content
      definition.dig("requestBody", "content") || {}
    end

    # @return [Array(Integer, String, Object)] status, content type and example of the first 2xx response
    def success_example
      status, response = definition["responses"].find { |code, _| code.start_with?("2") }
      content_type, media = (response["content"] || {}).first
      [status.to_i, content_type, OpenapiContract.example(media)]
    end

    # @return [Hash, nil] the schema of a response
    def response_schema(status, content_type = "application/json")
      definition.dig("responses", status.to_s, "content", content_type, "schema")
    end
  end

  module_function

  def document
    @document ||= JSON.parse(File.read(SPEC_FILE))
  end

  def version
    document.dig("info", "description")[/Wersja API:\*\*\s*([\d.]+)/, 1]
  end

  def schemas
    document.dig("components", "schemas")
  end

  # Literal segments win over parameters: `/auth/sessions` before `/auth/{referenceNumber}`.
  def operations
    @operations ||= begin
      all = document["paths"].flat_map do |template, item|
        VERBS.filter_map do |verb|
          next unless item[verb]

          Operation.new(verb: verb, template: template, definition: item[verb],
                        pattern: Regexp.new("\\A#{template.gsub(/\{([^}]+)\}/, '(?<\1>[^/]+)')}\\z"))
        end
      end
      all.sort_by { |operation| operation.template.count("{") }
    end
  end

  def operation(key)
    operations.find { |candidate| candidate.key == key } || raise(KeyError, "no operation #{key}")
  end

  def operation_for(verb, path)
    operations.find { |candidate| candidate.verb == verb && candidate.pattern.match?(path) }
  end

  def example(media)
    return nil unless media

    return media["example"] if media.key?("example")

    named = (media["examples"] || {}).values.first
    named && named["value"]
  end

  SAMPLE_STRINGS = { "date-time" => "2026-10-01T12:00:00+00:00", "date" => "2026-10-01", "byte" => "AAAA" }.freeze

  # A value that fits +schema+ (every property, one item per array), for a response the document
  # gives no example of.
  # @return [Object]
  def sample(schema, depth = 0)
    schema = resolve(schema)
    alternatives = schema["oneOf"] || schema["anyOf"]
    return sample(alternatives.first, depth) if alternatives
    return schema["enum"].first if schema["enum"]

    case schema["type"] || ("object" if schema["properties"] || schema["required"])
    when "object" then (schema["properties"] || {}).transform_values { |member| sample(member, depth + 1) }
    when "array" then depth > 8 ? [] : [sample(schema["items"], depth + 1)]
    else sample_scalar(schema)
    end
  end

  def sample_scalar(schema)
    case schema["type"]
    when "integer", "number" then schema["minimum"] || 1
    when "boolean" then true
    when "string" then SAMPLE_STRINGS.fetch(schema["format"], "x" * [schema["minLength"].to_i, 1].max)
    end
  end

  # @return [Hash] the schema with `$ref` and `allOf` folded in
  def resolve(schema)
    return schema unless schema.is_a?(Hash)

    return resolve(schemas.fetch(schema["$ref"].split("/").last)).merge(schema.except("$ref")) if schema["$ref"]
    return schema unless schema["allOf"]

    # allOf requires every part, the wrapper's own `required` and `properties` included.
    [*schema["allOf"].map { |part| resolve(part) }, schema.except("allOf")].reduce({}) do |acc, part|
      acc.merge(part) do |key, old, new|
        case key
        when "properties" then old.merge(new)
        when "required" then old | new
        else new
        end
      end
    end
  end

  # @return [Array<String>] the ways +value+ breaks +schema+ (empty when it conforms)
  def validate(schema, value, pointer = "$")
    schema = resolve(schema)
    return [] if !schema.is_a?(Hash) || schema.empty? || (value.nil? && schema["nullable"])

    alternatives = schema["oneOf"] || schema["anyOf"]
    if alternatives
      return [] if alternatives.any? { |alternative| validate(alternative, value, pointer).empty? }

      return ["#{pointer}: matches none of the alternatives"]
    end

    errors = []
    if schema["enum"] && !schema["enum"].include?(value)
      errors << "#{pointer}: #{value.inspect} is not one of #{schema['enum'].inspect}"
    end
    errors.concat(validate_type(schema, value, pointer))
  end

  def validate_type(schema, value, pointer)
    case schema["type"] || ("object" if schema["properties"] || schema["required"])
    when "object" then validate_object(schema, value, pointer)
    when "array" then validate_array(schema, value, pointer)
    when "string" then validate_string(schema, value, pointer)
    when "integer", "number", "boolean" then validate_scalar(schema, value, pointer)
    else []
    end
  end

  def validate_object(schema, value, pointer)
    return ["#{pointer}: expected an object"] unless value.is_a?(Hash)

    properties = schema["properties"] || {}
    errors = Array(schema["required"]).reject { |name| value.key?(name) }.map { |name| "#{pointer}: missing #{name}" }
    value.each do |name, member|
      member_schema = properties[name] || schema["additionalProperties"]
      next errors << "#{pointer}: unknown property #{name}" unless member_schema

      errors.concat(validate(member_schema, member, "#{pointer}.#{name}"))
    end
    errors
  end

  def validate_array(schema, value, pointer)
    return ["#{pointer}: expected an array"] unless value.is_a?(Array)

    errors = []
    errors << "#{pointer}: too few items" if schema["minItems"] && value.size < schema["minItems"]
    errors << "#{pointer}: too many items" if schema["maxItems"] && value.size > schema["maxItems"]
    value.each_with_index { |item, index| errors.concat(validate(schema["items"], item, "#{pointer}[#{index}]")) }
    errors
  end

  def validate_string(schema, value, pointer)
    return ["#{pointer}: expected a string"] unless value.is_a?(String)

    errors = []
    errors << "#{pointer}: too short" if schema["minLength"] && value.length < schema["minLength"]
    errors << "#{pointer}: too long" if schema["maxLength"] && value.length > schema["maxLength"]
    if schema["pattern"] && !value.match?(Regexp.new(schema["pattern"]))
      errors << "#{pointer}: #{value.inspect} does not match #{schema['pattern']}"
    end
    errors << "#{pointer}: #{value.inspect} is not a #{schema['format']}" unless format?(schema["format"], value)
    errors
  end

  # The zone stays optional: KSeF reads a date-time without one as Warsaw time.
  DATE_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\z/i
  DATE = /\A\d{4}-\d{2}-\d{2}\z/
  BASE64 = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}

  def format?(format, value)
    case format
    when "date-time" then value.match?(DATE_TIME) && parses? { Time.iso8601(value) }
    when "date" then value.match?(DATE) && parses? { Date.iso8601(value) }
    when "byte" then value.match?(BASE64)
    else true
    end
  end

  def parses?
    yield
    true
  rescue ArgumentError
    false
  end

  SCALARS = { "integer" => Integer, "number" => Numeric, "boolean" => [TrueClass, FalseClass] }.freeze
  INTEGER_FORMATS = { "int32" => -(2**31)..((2**31) - 1), "int64" => -(2**63)..((2**63) - 1) }.freeze

  def validate_scalar(schema, value, pointer)
    expected = Array(SCALARS[schema["type"]])
    return ["#{pointer}: expected #{schema['type']}"] unless expected.any? { |type| value.is_a?(type) }

    errors = []
    errors << "#{pointer}: below #{schema['minimum']}" if schema["minimum"] && value < schema["minimum"]
    errors << "#{pointer}: above #{schema['maximum']}" if schema["maximum"] && value > schema["maximum"]
    range = INTEGER_FORMATS[schema["format"]]
    errors << "#{pointer}: #{value} is out of #{schema['format']}" if range && !range.cover?(value)
    errors
  end

  # Whether a dotted field path ("package.parts.[].url") exists in +schema+.
  def field?(schema, path)
    current = resolve(schema)
    path.split(".").each do |segment|
      return false unless current.is_a?(Hash)

      current = resolve(segment == "[]" ? current["items"] : (current["properties"] || {})[segment])
    end
    !current.nil?
  end
end
