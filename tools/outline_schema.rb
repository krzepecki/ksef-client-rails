# frozen_string_literal: true

# Prints the element tree of a packaged form schema ({Ksef::Invoices::Validator#outline}).
#
#   bundle exec ruby tools/outline_schema.rb                       # Faktura, 2 levels
#   bundle exec ruby tools/outline_schema.rb Faktura/Fa/FaWiersz   # one subtree, full depth
#   rake "xsd:outline[Faktura/Fa/Adnotacje]"
#
# KSEF_FORM_CODE switches the form (e.g. "FA (2)", "FA_RR (1)"); KSEF_DEPTH sets the depth.

require_relative "../lib/ksef"

target = ARGV[0] || "Faktura"
depth = ENV["KSEF_DEPTH"] && (Integer(ENV["KSEF_DEPTH"], exception: false) || abort("KSEF_DEPTH must be an integer"))

begin
  validator = Ksef::Invoices::Validator.new(form_code: ENV["KSEF_FORM_CODE"] || Ksef::FormCode::FA3)
  puts "#{validator.system_code} — #{target}"
  puts "-" * 78
  puts validator.outline(target, depth: depth)
rescue Ksef::ConfigurationError => e
  abort e.message
end
