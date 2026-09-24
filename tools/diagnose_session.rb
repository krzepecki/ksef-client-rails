# frozen_string_literal: true

# Diagnostics for a rejected invoice on live KSeF (TEST unless KSEF_ENV is set).
#
#   cd ksef-client-rails
#   KSEF_TOKEN=... KSEF_NIP=... \
#   KSEF_SESSION=20260819-SO-0123456789-ABCDEF0123-45 \
#   KSEF_INVOICE=20260819-EE-9876543210-FEDCBA9876-54 \
#   bundle exec ruby <this-file>
#
# Instead of KSEF_TOKEN you may pass a ready KSEF_ACCESS_TOKEN (skipping re-authentication). An
# authentication session the tool opens itself is revoked at the end.

require "ksef"
require "json"

session_ref = ENV.fetch("KSEF_SESSION")
invoice_ref = ENV["KSEF_INVOICE"]
config = Ksef::Configuration.new(environment: (ENV["KSEF_ENV"] || "test").to_sym)

access_token = ENV["KSEF_ACCESS_TOKEN"]
if access_token.nil? || access_token.empty?
  result = Ksef::Auth::Coordinator.new(Ksef::Client.new(config: config)).authenticate_with_token(
    context: { nip: ENV.fetch("KSEF_NIP") },
    token: ENV.fetch("KSEF_TOKEN"),
    poll: { interval: 2, timeout: 90 }
  )
  access_token = result.access_token
  puts "# authenticated, accessToken valid until #{result.access_token_valid_until}"
end

begin
  client = Ksef::Client.new(access_token: access_token, config: config)

  puts "\n=== SESSION STATUS #{session_ref} ==="
  puts JSON.pretty_generate(client.sessions.status(session_ref))

  if invoice_ref
    puts "\n=== INVOICE STATUS #{invoice_ref} ==="
    puts JSON.pretty_generate(client.sessions.invoice(session_ref, invoice_ref))
  end

  puts "\n=== REJECTED INVOICES IN THE SESSION (with full errors) ==="
  client.sessions.failed_invoices(session_ref).each { |inv| puts JSON.pretty_generate(inv) }
ensure
  # Only the session this tool opened; its own rescue keeps a failed revocation from hiding the error.
  if result
    begin
      Ksef::Client.new(config: config).auth.revoke_current_session(token: result.refresh_token)
      puts "\n# authentication session #{result.reference_number} revoked"
    rescue StandardError => e
      warn "# could not revoke the authentication session #{result.reference_number}: #{e.class}: #{e.message}"
    end
  end
end
