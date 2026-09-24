# frozen_string_literal: true

require "bundler/gem_tasks"
require "shellwords"

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
rescue LoadError
  # rspec unavailable — the :spec task is skipped
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  # rubocop unavailable
end

namespace :xsd do
  desc "Prints the field tree of a form schema (no argument: Faktura, 2 levels)"
  task :outline, [:path] do |_task, args|
    sh(["ruby", "tools/outline_schema.rb", *[args[:path]].compact].shelljoin)
  end

  desc "Writes examples/fa3_{minimal,typical,full}.xml from Ksef::Invoices::Sample"
  task :examples do
    require_relative "lib/ksef"
    %i[minimal typical full].each do |level|
      invoice = Ksef::Invoices::Sample.public_send(level, seller_nip: "5555555555", invoice_number: "FV/2026/02/1",
                                                          issue_date: Date.new(2026, 2, 1))
      File.write("examples/fa3_#{level}.xml", invoice.to_xml(created_at: Time.utc(2026, 2, 1, 10)))
    end
  end

  desc "Validates invoices against the FA(3) schema in schemas/ (no argument: the three examples)"
  task :validate, [:path] do |_task, args|
    files = [args[:path], *args.extras].compact
    sh(["ruby", "tools/validate_invoice.rb", *files].shelljoin)
  end
end

namespace :contract do
  desc "Compares the OpenAPI fixture with the documents the live KSeF servers publish (needs network)"
  task :drift do
    sh "ruby tools/openapi_drift.rb"
  end
end

namespace :e2e do
  desc "Runs every flow against live KSeF TEST with a throwaway self-signed seal (needs network)"
  task :test do
    sh "ruby tools/e2e_test_env.rb"
  end
end

# The Python oracle needs its own venv — it cannot be version-controlled, so `oracle:venv`
# creates it on demand (once, with network access). CI installs the dependencies system-wide.
ORACLE_PYTHON = "tools/oracle/venv/bin/python"

namespace :oracle do
  desc "Creates the oracle virtualenv with its dependencies (once, requires network)"
  task :venv do
    next if File.executable?(ORACLE_PYTHON)

    sh "python3 -m venv tools/oracle/venv"
    sh "tools/oracle/venv/bin/pip install --quiet cryptography lxml"
  end

  desc "Verifies crypto (AES without IV prefix, RSA-OAEP, the KSeF-token plaintext, CSR RDN order and types) " \
       "with the independent Python oracle"
  task crypto: :venv do
    sh "ruby tools/oracle/gen_crypto.rb | #{ORACLE_PYTHON} tools/oracle/verify_crypto.py"
  end

  desc "Verifies the XAdES signature (reference digests, RSA/EC SignatureValue, SigningCertificate) " \
       "with the Python oracle"
  task xades: :venv do
    sh "ruby tools/oracle/gen_xades.rb | #{ORACLE_PYTHON} tools/oracle/verify_xades.py"
  end

  desc "Runs every offline oracle"
  task all: %i[crypto xades]
end

task default: %i[spec rubocop xsd:validate]
