# frozen_string_literal: true

# Validates an invoice offline against the form schema and KSeF's XML rules — what fails here, KSeF
# rejects too (the messages are libxml2's, not KSeF's).
#
#   bundle exec ruby tools/validate_invoice.rb [invoice.xml ...]
#   rake xsd:validate                 # examples/fa3_{minimal,typical,full}.xml
#   rake "xsd:validate[invoice.xml]"
#
# KSEF_FORM_CODE switches the form (e.g. "FA_RR (1)"). Exit code 1 on any mismatch — CI-friendly.

require_relative "../lib/ksef"

begin
  validator = Ksef::Invoices::Validator.new(form_code: ENV["KSEF_FORM_CODE"] || Ksef::FormCode::FA3)
rescue Ksef::ConfigurationError => e
  abort e.message
end

documents =
  if ARGV.empty?
    Dir[File.expand_path("../examples/fa3_*.xml", __dir__)].map { |path| [File.basename(path), File.read(path)] }
  else
    ARGV.map { |path| [path, File.read(path)] }
  end

results = documents.map do |label, xml|
  messages = validator.validate(xml)
  if messages.empty?
    puts "[PASS] #{label}"
  else
    puts "[FAIL] #{label} — #{messages.size} validation errors"
    messages.each { |message| puts "  - #{message}" }
  end
  messages.empty?
end

puts results.all? ? "\n#{results.size}/#{results.size} documents match #{validator.system_code}" : "\nValidation failed"
exit(results.all? ? 0 : 1)
