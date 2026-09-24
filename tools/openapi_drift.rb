# frozen_string_literal: true

# Compares the OpenAPI document the gem targets (spec/fixtures/openapi/) with the ones the live KSeF
# servers publish: API version, operations added or removed, schemas whose structure changed
# (descriptions and examples aside). Exit status 1 when a server drifts — the signal to review
# api-changelog.md (CIRFMF/ksef-api) and bump the fixture together with Ksef::API_VERSION.
#
#   bundle exec ruby tools/openapi_drift.rb [test demo prod]   # default: all three

require "json"
require "net/http"
require_relative "../lib/ksef/version"

FIXTURE = File.expand_path("../spec/fixtures/openapi/ksef-api-#{Ksef::API_VERSION}.json", __dir__)
SERVERS = {
  "test" => "https://api-test.ksef.mf.gov.pl/docs/v2/openapi.json",
  "demo" => "https://api-demo.ksef.mf.gov.pl/docs/v2/openapi.json",
  "prod" => "https://api.ksef.mf.gov.pl/docs/v2/openapi.json"
}.freeze
PROSE = %w[description summary example examples].freeze

def version(document)
  document.dig("info", "description").to_s[/Wersja API:\*\*\s*([^<]+)/, 1].to_s.strip
end

# "2.8.1 (build …)" → "2.8.1", compared whole: 2.8.10 is not 2.8.1.
def same_version?(document)
  version(document)[/\A\d+(?:\.\d+)*/] == Ksef::API_VERSION
end

def operations(document)
  document["paths"].each_with_object({}) do |(path, item), ops|
    (item.keys & %w[get post put delete patch]).each { |verb| ops["#{verb.upcase} #{path}"] = item[verb] }
  end
end

# The document without its prose, so that reworded descriptions do not count as drift. The keys of a
# `properties` map are property names, so a property called `description` keeps its schema.
def structure(node, names: false)
  case node
  when Hash
    (names ? node : node.except(*PROSE)).to_h do |key, value|
      [key, structure(value, names: !names && key == "properties")]
    end
  when Array then node.map { |value| structure(value) }
  else node
  end
end

def compare(server, baseline, live)
  ours = operations(baseline)
  theirs = operations(live)
  # DEMO and PROD do not publish the TEST-only /testdata endpoints or the schemas only they use.
  ours = ours.reject { |key, _| key.include?("/testdata") } unless server == "test"
  ours_schemas = baseline.dig("components", "schemas")
  theirs_schemas = live.dig("components", "schemas")
  {
    "added operations" => theirs.keys - ours.keys,
    "removed operations" => ours.keys - theirs.keys,
    "changed operations" => (ours.keys & theirs.keys).reject { |key| structure(ours[key]) == structure(theirs[key]) },
    "added schemas" => theirs_schemas.keys - ours_schemas.keys,
    "changed schemas" => (ours_schemas.keys & theirs_schemas.keys).reject do |name|
      structure(ours_schemas[name]) == structure(theirs_schemas[name])
    end
  }.reject { |_, names| names.empty? }
end

baseline = JSON.parse(File.read(FIXTURE))
puts "fixture: #{version(baseline)}, #{operations(baseline).size} operations"
drifted = (ARGV.empty? ? SERVERS.keys : ARGV).map do |server|
  live = JSON.parse(Net::HTTP.get(URI(SERVERS.fetch(server))))
  differences = compare(server, baseline, live)
  same_version = same_version?(live)
  puts "#{server}: #{version(live)} — #{differences.empty? && same_version ? 'matches the fixture' : 'DRIFT'}"
  differences.each { |kind, names| puts "  #{kind}: #{names.join(', ')}" }
  !(differences.empty? && same_version)
end

exit(drifted.any? ? 1 : 0)
