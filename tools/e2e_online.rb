# frozen_string_literal: true

# Manual e2e smoke test of the interactive session against live KSeF (TEST unless KSEF_ENV is set).
#
#   KSEF_TOKEN=... KSEF_NIP=... [KSEF_ENV=demo] bundle exec ruby tools/e2e_online.rb [path/to/invoice.xml]
#
# Without an argument it sends Ksef::Invoices::Sample.minimal. Runs: auth → open → send → close → UPO,
# then revokes its authentication session. PROD issues legally binding invoices: it needs
# KSEF_CONFIRM_PROD=1 and an invoice file (the sample's parties are placeholders).

require "ksef"
require "json"

nip = ENV.fetch("KSEF_NIP")
config = Ksef::Configuration.new(environment: (ENV["KSEF_ENV"] || "test").to_sym)

if config.environment == :prod
  abort "refusing to run on PROD (legally binding invoices): set KSEF_CONFIRM_PROD=1" unless ENV["KSEF_CONFIRM_PROD"] == "1"
  abort "refusing to send the sample invoice (placeholder parties) to PROD: pass an invoice file" if ARGV.empty?
end

invoice_xml =
  if ARGV[0]
    File.read(ARGV[0])
  else
    Ksef::Invoices::Sample.minimal(seller_nip: nip, invoice_number: "FV/E2E/#{Time.now.strftime('%Y%m%d-%H%M%S')}").to_xml
  end

auth = Ksef::Auth::Coordinator.new(Ksef::Client.new(config: config)).authenticate_with_token(
  context: { nip: nip }, token: ENV.fetch("KSEF_TOKEN"), poll: { interval: 2, timeout: 90 }
)
puts "auth OK — accessToken valid until #{auth.access_token_valid_until}"

begin
  client = Ksef::Client.new(access_token: auth.access_token, config: config)
  session = Ksef::Sessions::Online.open(client, form_code: Ksef::FormCode::FA3)
  puts "session: #{session.reference_number}"

  sent = session.send_invoice(invoice_xml)
  puts "invoice: #{sent.reference_number} (hash #{sent.invoice_metadata.hash_sha})"

  session.close
  puts "session closed — waiting for the UPO…"

  begin
    upo = session.wait_for_upo(sent.reference_number, poll: { interval: 3, timeout: 180 })
    puts "UPO OK (#{upo.bytesize} B)"
    puts upo.lines.grep(/NumerKSeF|KodFormularza|NumerReferencyjny/).map(&:strip).first(5)
    puts JSON.pretty_generate(client.sessions.invoice(session.reference_number, sent.reference_number))
  rescue Ksef::Error => e
    puts "REJECTED: #{e.message}"
    puts JSON.pretty_generate(e.body) if e.respond_to?(:body) && e.body
  end
ensure
  # Its own rescue, so that a failed revocation never hides the error that ended the run.
  begin
    Ksef::Client.new(config: config).auth.revoke_current_session(token: auth.refresh_token)
    puts "authentication session #{auth.reference_number} revoked"
  rescue StandardError => e
    warn "could not revoke the authentication session #{auth.reference_number}: #{e.class}: #{e.message}"
  end
end
