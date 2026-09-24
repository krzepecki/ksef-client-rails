# frozen_string_literal: true

# Live end-to-end run of the whole gem against KSeF TEST — no credentials needed. It signs in with a
# fresh self-signed seal (`organizationIdentifier = VATPL-<NIP>`) for a random NIP: TEST accepts
# self-signed certificates, and the seal makes it the owner of that context. TEST data is shared
# between integrators and has no legal effect.
#
#   bundle exec ruby tools/e2e_test_env.rb [report.json]
#
# Every step prints PASS/FAIL (a failed step skips the ones that need it); the exit status is the
# number of failed steps. What it creates (a KSeF token, an Offline certificate, its authentication
# sessions) is revoked at the end, also when the run is interrupted.

require "ksef"
require "json"
require "logger"
require "net/http"
require "openssl"
require "securerandom"

$stdout.sync = true

# Runs the steps and keeps their outcome.
class LiveCheck
  SPEC_URL = "https://api-test.ksef.mf.gov.pl/docs/v2/openapi.json"
  POLL = { interval: 2, max_interval: 10, timeout: 300 }.freeze

  Outcome = Struct.new(:name, :status, :seconds, :detail, keyword_init: true)

  def initialize(report_path)
    @report_path = report_path
    @outcomes = []
    @config = Ksef::Configuration.new(environment: :test)
    @config.logger = Logger.new($stderr, level: :warn) # shows X-System-Warning and retries
    @base = Ksef::Client.new(config: @config)
    @nip = random_nip
    @stamp = Time.now.strftime("%Y%m%d-%H%M%S")
    @started = Time.now
  end

  def run
    puts "ksef-client-rails #{Ksef::VERSION} (contract #{Ksef::API_VERSION}) against KSeF TEST, context NIP #{@nip}"
    begin
      preflight
      authenticate
      tokens_and_limits
      invoices
      downloads
      collective_identifiers
      certificates
      misc
    ensure
      cleanup # every cleanup step rescues its own failure, so it cannot replace the error in flight
    end
    report
  end

  private

  # --- steps ------------------------------------------------------------------------------------

  def preflight
    step("server API version matches the contract") do
      version = server_version
      # "2.8.1 (build …)" → "2.8.1", compared whole: 2.8.10 is not 2.8.1.
      unless version[/\A\d+(?:\.\d+)*/] == Ksef::API_VERSION
        raise "server runs #{version}, the gem targets #{Ksef::API_VERSION}"
      end

      version
    end
    step("Ministry public keys") do
      usages = @base.security.public_key_certificates.flat_map { |cert| cert["usage"] }.uniq
      missing = [Ksef::Crypto::PublicKeys::SYMMETRIC_KEY_ENCRYPTION, Ksef::Crypto::PublicKeys::KSEF_TOKEN_ENCRYPTION] - usages
      raise "missing usages #{missing}" unless missing.empty?

      usages.join(", ")
    end
  end

  def authenticate
    @auth = step("XAdES login with a self-signed RSA seal") { xades_login(OpenSSL::PKey::RSA.new(2048)) }
    return unless @auth

    @ec_auth = step("XAdES login with a self-signed EC P-256 seal") { xades_login(OpenSSL::PKey::EC.generate("prime256v1")) }
    @manager = Ksef::TokenManager.new(@base, access_token: @auth.access_token, refresh_token: @auth.refresh_token,
                                             access_token_valid_until: @auth.access_token_valid_until)
    step("access token refresh (TokenManager)") { @manager.force_refresh! && "refreshed" }
    @client = @base.with_access_token(-> { @manager.access_token })
    step("authentication sessions list") do
      sessions = @client.auth.sessions.first(20)
      raise "the current session is not listed" unless sessions.any? { |session| session["isCurrent"] }

      "#{sessions.size} sessions, current one listed"
    end
  end

  def tokens_and_limits
    return unless @client

    step("limits: context, subject, API rate limits") do
      [@client.limits.context, @client.limits.subject, @client.limits.rate_limits].map(&:size).join("/") + " keys"
    end
    @ksef_token = step("KSeF token: generate and wait until active") do
      generated = @client.tokens.generate(permissions: %w[InvoiceRead InvoiceWrite], description: "gem e2e #{@stamp}")
      Ksef::Polling.run(**POLL, description: "token") do
        case (status = @client.tokens.status(generated["referenceNumber"])["status"])
        when "Active" then generated
        when "Pending" then Ksef::Polling.pending
        else raise "the token ended as #{status}"
        end
      end
    end
    return unless @ksef_token

    step("tokens list filtered by status (repeated query keys)") do
      reference = @ksef_token["referenceNumber"]
      active = @client.tokens.list(status: %w[Active]).map { |token| token["referenceNumber"] }.to_a
      revoked = @client.tokens.list(status: %w[Revoked Failed]).map { |token| token["referenceNumber"] }.to_a
      raise "the active token is missing from status=Active" unless active.include?(reference)
      raise "the filter is ignored: the active token is listed as revoked" if revoked.include?(reference)

      "#{active.size} active, filter honoured"
    end
    @token_auth = step("login with the KSeF token (RSA-OAEP)") do
      Ksef::Auth::Coordinator.new(@base).authenticate_with_token(context: { nip: @nip }, token: @ksef_token["token"],
                                                                 poll: POLL)
    end
  end

  def invoices
    return unless @client

    @online = step("online session: validate → send → close → UPO → KSeF number") { online_session }
    step("Ksef::Invoices::Sample typical and full accepted in one session") { typical_and_full }
    step("sessions list (sessionType + filters)") do
      listed = @client.sessions.list(session_type: "Online", reference_number: @online&.dig(:session)).first(5)
      raise "the session is not listed" if @online && listed.none? { |s| s["referenceNumber"] == @online[:session] }

      "#{listed.size} listed"
    end
    @batch_zip = step("batch session, ZIP in several parts → processed → UPO") { batch_session(:zip) }
    @batch_tar_gz = step("batch session, tar.gz (batchFile.compressionType = TarGz) → processed") { batch_session(:tar_gz) }
  end

  def downloads
    numbers = issued_ksef_numbers
    return if numbers.empty?

    step("invoice download by KSeF number") do
      xml = @client.invoices.get_by_ksef_number(numbers.first)
      raise "not an FA(3) invoice" unless xml.include?("Faktura")

      "#{xml.bytesize} B"
    end
    step("metadata query (Desc)") do
      found = wait_for("our invoices in the metadata query") do
        listed = @client.invoices.query_metadata(filters: filters("Invoicing"), sort_order: "Desc").map { |m| m["ksefNumber"] }.to_a
        listed if (numbers - listed).empty?
      end
      "#{found.size} invoices, all of ours"
    end
    %w[Zip TarGz].each do |type|
      step("export #{type}: decrypt, verify, unpack, pair with _metadata.json") { export(type, numbers) }
    end
    return unless step("incremental sync (HWM)") { incremental_sync(numbers) }

    step("incremental sync from 91 days back: a closed 90-day window, then an open one") { long_window_sync(numbers) }
  end

  def collective_identifiers
    numbers = issued_ksef_numbers
    return if numbers.size < 2

    step("collective identifier: generate, query, list invoices, look up by KSeF number") do
      collective = @client.collective_identifiers
      created = collective.generate(invoices: numbers.first(2).map { |number| { "ksefNumber" => number } })
      id = created["collectiveIdentifierNumber"]
      queried = collective.query(filters: { "dateCreatedFrom" => iso(Time.now - 3600), "dateCreatedTo" => iso(Time.now + 60) })
                          .map { |entry| entry["collectiveIdentifierNumber"] }.to_a
      listed = collective.invoices(collective_identifier_numbers: [id]).map { |entry| entry["ksefNumber"] }.to_a
      by_number = collective.by_ksef_number(numbers.first).map { |entry| entry["collectiveIdentifierNumber"] }.to_a
      raise "not queryable" unless queried.include?(id)
      raise "invoices missing: #{numbers.first(2) - listed}" unless (numbers.first(2) - listed).empty?
      raise "not found by KSeF number" unless by_number.include?(id)

      id
    end
  end

  def certificates
    return unless @client

    step("certificate limits") { @client.certificates.limits.keys.join(", ") }
    @certificate = step("Offline certificate: enrollment data → CSR → enroll → issued → retrieve") { enroll_certificate }
    return unless @certificate

    step("CODE II link signed with the Offline certificate's key") { code_two_link }
    step("certificates query lists it") do
      serials = @client.certificates.query(body: {}).map { |cert| cert["certificateSerialNumber"] }.to_a
      raise "not listed" unless serials.include?(@certificate[:serial])

      "#{serials.size} certificates"
    end
    step("TEST data: shorten the certificate's validity (PUT /testdata/certificates)") do
      @client.test_data.update_certificate(@certificate[:serial], valid_to: iso(Time.now + 120))
      "valid to #{iso(Time.now + 120)}"
    end
  end

  def misc
    return unless @client

    step("permissions: own, entity roles, attachment status") do
      own = @client.permissions.query_personal.first(10)
      roles = @client.permissions.query_entity_roles.first(10)
      "#{own.size} own, #{roles.size} roles, attachments #{@client.permissions.attachment_status.inspect}"
    end
    step("Peppol providers (anonymous, as the contract declares)") { "#{@client.peppol.query.first(5).size} listed" }
    step("an unknown session maps to a typed error") do
      @client.sessions.status("20250101-SO-0000000000-0000000000-00")
      raise "no error"
    rescue Ksef::ApiError => e
      "#{e.class.name.split('::').last} HTTP #{e.status} codes #{e.codes}"
    end
  end

  def cleanup
    if @ksef_token
      step("revoke the KSeF token") do
        @client.tokens.revoke(@ksef_token["referenceNumber"])
        "revoked"
      end
    end
    if @certificate
      step("revoke the Offline certificate") do
        @client.certificates.revoke(@certificate[:serial], revocation_reason: "Superseded")
        "revoked"
      end
    end
    step("TEST data: block and unblock the context (anonymous)") do
      body = { "contextIdentifier" => { "type" => "Nip", "value" => @nip } }
      @base.test_data.block_context(body: body)
      @base.test_data.unblock_context(body: body)
      "blocked, unblocked"
    end
    [@token_auth, @ec_auth, @auth].compact.each do |auth|
      step("revoke the authentication session #{auth.reference_number}") do
        @base.auth.revoke_current_session(token: auth.refresh_token)
        "revoked"
      end
    end
  end

  # --- building blocks --------------------------------------------------------------------------

  def xades_login(key)
    cert = seal(key)
    Ksef::Auth::Coordinator.new(@base).authenticate(
      context: { nip: @nip }, signer: Ksef::Xades::Signer.new(cert: cert, key: key),
      subject_identifier_type: :certificate_subject, verify_certificate_chain: false, poll: POLL
    )
  end

  def online_session
    xml = sample_xml(:minimal, "FV/E2E/#{@stamp}/1")
    Ksef::Invoices::Validator.new.validate!(xml)
    session = Ksef::Sessions::Online.open(@client)
    sent = session.send_invoice(xml)
    session.close
    upo = session.wait_for_upo(sent.reference_number, poll: POLL)
    info = @client.sessions.invoice(session.reference_number, sent.reference_number)
    raise "the UPO does not carry the hash" unless upo.include?(sent.invoice_metadata.hash_sha)
    raise "no KSeF number: #{info['status']}" unless info["ksefNumber"]

    link = Ksef::Qr::VerificationLink.from_client(@client).online(seller_nip: @nip, invoice_xml: xml) # date from P_1
    Ksef::Qr::Code.new(link, label: info["ksefNumber"]).as_svg
    { session: session.reference_number, ksef_numbers: [info["ksefNumber"]], detail: info["ksefNumber"] }
  end

  def typical_and_full
    session = Ksef::Sessions::Online.open(@client)
    sent = %i[typical full].map do |level|
      xml = sample_xml(level, "FV/E2E/#{@stamp}/#{level}")
      Ksef::Invoices::Validator.new.validate!(xml)
      session.send_invoice(xml)
    end
    session.close
    numbers = sent.map do |invoice|
      session.wait_for_upo(invoice.reference_number, poll: POLL)
      info = @client.sessions.invoice(session.reference_number, invoice.reference_number)
      info["ksefNumber"] || raise("no KSeF number for #{invoice.reference_number}: #{info['status']}")
    end
    numbers.join(", ")
  end

  def batch_session(compression)
    invoices = (1..2).to_h do |i|
      ["invoice-#{i}.xml", sample_xml(:minimal, "FV/E2E/#{@stamp}/#{compression}-#{i}")]
    end
    result = Ksef::Batch::Uploader.new(@client, part_size: 1500).call(invoices: invoices, compression: compression)
    status = Ksef::Polling.run(**POLL, description: "batch #{result.reference_number}") do
      current = @client.sessions.status(result.reference_number)
      code = current.dig("status", "code")
      raise "batch session failed: #{current['status']}" if code.to_i >= 400

      code == 200 ? current : Ksef::Polling.pending
    end
    # Code 200 means at least one invoice was accepted, so every count and every invoice is checked.
    successful, failed = status.values_at("successfulInvoiceCount", "failedInvoiceCount")
    unless successful == invoices.size && failed.to_i.zero?
      raise "#{successful.inspect} of #{invoices.size} invoices accepted, #{failed.inspect} rejected"
    end
    accepted = @client.sessions.invoices(result.reference_number).to_a
    names = accepted.map { |inv| inv["invoiceFileName"].to_s }.sort
    raise "per-invoice file names #{names} do not match #{invoices.keys}" unless names == invoices.keys.sort

    unnumbered = accepted.reject { |inv| inv.dig("status", "code") == 200 && inv["ksefNumber"] }
    raise "invoices without a KSeF number: #{unnumbered.map { |inv| [inv['invoiceFileName'], inv['status']] }}" unless unnumbered.empty?

    pages = Array(status.dig("upo", "pages"))
    pages.each { |page| @client.sessions.session_upo(result.reference_number, page["referenceNumber"]) }
    { session: result.reference_number, ksef_numbers: accepted.map { |inv| inv["ksefNumber"] },
      detail: "#{result.parts.size} parts, #{accepted.size} invoices, #{pages.size} UPO page(s)" }
  end

  def export(type, numbers)
    result = Ksef::Invoices::Export.new(@client).call(filters: filters("Invoicing"), compression_type: type, poll: POLL)
    expected = type == "Zip" ? :zip : :tar_gz
    raise "package is #{result.compression.inspect}, expected #{expected}" unless result.compression == expected

    exported = result.metadata.map { |meta| meta["ksefNumber"] }
    files = result.each_entry.map { |name, _bytes| name }
    missing = numbers - exported
    raise "missing from _metadata.json: #{missing}" unless missing.empty?
    raise "missing files: #{numbers.map { |n| "#{n}.xml" } - files}" unless (numbers.map { |n| "#{n}.xml" } - files).empty?

    "#{result.package['invoiceCount']} invoices, #{files.size} files, #{result.bytes.bytesize} B"
  end

  # Permanent storage (and with it the HWM) follows acceptance asynchronously, so the sync is retried
  # for a while until our invoices appear.
  def incremental_sync(numbers)
    from = iso(@started - 600)
    deadline = Time.now + 300
    loop do
      sync = Ksef::Sync::Incremental.new(@client, from: from, subject_type: "Subject1", page_limit: 20)
      seen = {}
      sync.each_invoice { |xml, meta| seen[meta["ksefNumber"]] = xml }
      if (numbers - seen.keys).empty?
        raise "metadata not paired" if seen.key?(nil)

        return "#{seen.size} invoices with metadata; next run from #{sync.hwm}"
      end
      raise "after 5 minutes still missing #{numbers - seen.keys} (HWM #{sync.hwm})" if Time.now > deadline

      sleep 20
    end
  end

  # A start older than the 100-day dateRange limit: the gem sends a closed window (dateRange.to) first,
  # then an open one. Run once, after the HWM step — exports are limited to 20 an hour.
  def long_window_sync(numbers)
    sync = Ksef::Sync::Incremental.new(@client, from: iso(Time.now - (91 * 86_400)), subject_type: "Subject1",
                                                page_limit: 5)
    seen = {}
    sync.each_invoice { |_xml, meta| seen[meta["ksefNumber"]] = true }
    missing = numbers - seen.keys
    raise "missing #{missing} (HWM #{sync.hwm})" unless missing.empty?

    "#{seen.size} invoices; next run from #{sync.hwm}"
  end

  def enroll_certificate
    data = @client.certificates.enrollment_data
    csr = Ksef::Crypto::Csr.generate_ecdsa(data)
    enrollment = @client.certificates.enroll(certificate_name: "gem e2e #{@stamp}", certificate_type: "Offline",
                                             csr: csr.csr_der_base64)
    serial = Ksef::Polling.run(**POLL, description: "certificate enrollment") do
      status = @client.certificates.enrollment_status(enrollment["referenceNumber"])
      case status.dig("status", "code")
      when 200 then status["certificateSerialNumber"]
      when 100 then Ksef::Polling.pending
      else raise "enrollment rejected: #{status['status']}"
      end
    end
    der = @client.certificates.retrieve(certificate_serial_numbers: [serial])["certificates"].first["certificate"]
    cert = OpenSSL::X509::Certificate.new(Base64.decode64(der))
    raise "the certificate does not hold the CSR's key" unless cert.check_private_key(csr.private_key)

    { serial: serial, cert: cert, key: csr.private_key, detail: "serial #{serial}" }
  end

  def code_two_link
    xml = sample_xml(:minimal, "FV/E2E/#{@stamp}/offline")
    link = Ksef::Qr::VerificationLink.from_client(@client).offline(
      context_type: "Nip", context_value: @nip, seller_nip: @nip, certificate_serial: @certificate[:serial],
      private_key: @certificate[:key], invoice_xml: xml
    )
    signed, signature = link.sub(%r{\Ahttps://}, "").rpartition("/").values_at(0, 2)
    raw = Base64.urlsafe_decode64(signature + ("=" * ((4 - (signature.length % 4)) % 4)))
    der = OpenSSL::ASN1::Sequence.new([raw[0, 32], raw[32, 32]].map { |half| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(half, 2)) }).to_der
    raise "the signature does not verify with the KSeF certificate" unless @certificate[:cert].public_key.verify("SHA256", der, signed)

    Ksef::Qr::Code.new(link, label: "CERTYFIKAT").as_svg
    link
  end

  # --- helpers ----------------------------------------------------------------------------------

  def step(name)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    record(name, :pass, started, describe(value))
    value
  rescue StandardError => e
    record(name, :fail, started, "#{e.class}: #{e.message}"[0, 400])
    nil
  end

  def record(name, status, started, detail)
    seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    @outcomes << Outcome.new(name: name, status: status, seconds: seconds, detail: detail)
    puts format("[%s] %-78s %6.1fs  %s", status.to_s.upcase, name, seconds, detail)
  end

  # Never prints a step's raw result — a generated KSeF token, for one, is a secret.
  def describe(value)
    case value
    when Hash then value[:detail] || value["referenceNumber"] || "ok"
    when Ksef::Auth::Coordinator::Result then "session #{value.reference_number}"
    else value.to_s[0, 160]
    end
  end

  def report
    failed = @outcomes.count { |outcome| outcome.status == :fail }
    puts "\n#{@outcomes.size - failed}/#{@outcomes.size} steps passed"
    if @report_path
      File.write(@report_path, JSON.pretty_generate(
                                 gem: Ksef::VERSION, contract: Ksef::API_VERSION, server: @server_version,
                                 context_nip: @nip, at: @started.utc.iso8601, steps: @outcomes.map(&:to_h)
                               ))
    end
    failed
  end

  def wait_for(what, timeout: 180)
    deadline = Time.now + timeout
    loop do
      value = yield
      return value if value
      raise "#{what}: not there after #{timeout} s" if Time.now > deadline

      sleep 10
    end
  end

  def issued_ksef_numbers
    [@online, @batch_zip, @batch_tar_gz].compact.flat_map { |issued| issued[:ksef_numbers] }
  end

  def filters(date_type)
    { "subjectType" => "Subject1", "dateRange" => { "dateType" => date_type, "from" => iso(@started - 600) } }
  end

  def iso(time)
    time.utc.iso8601(3)
  end

  def server_version
    body = Net::HTTP.get(URI(SPEC_URL))
    @server_version = JSON.parse(body).dig("info", "description")[/Wersja API:\*\*\s*([^<]+)/, 1].strip
  end

  # A self-signed company seal; KSeF matches its organizationIdentifier against the context NIP.
  def seal(key)
    name = OpenSSL::X509::Name.new([["CN", "ksef-client-rails e2e"], ["O", "ksef-client-rails e2e"],
                                    ["2.5.4.97", "VATPL-#{@nip}", OpenSSL::ASN1::UTF8STRING], ["C", "PL"]])
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(64)
    cert.subject = cert.issuer = name
    cert.public_key = OpenSSL::PKey.read(key.public_to_der)
    cert.not_before = Time.now - 300
    cert.not_after = Time.now + 86_400
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert
  end

  def sample_xml(level, invoice_number)
    Ksef::Invoices::Sample.public_send(level, seller_nip: @nip, invoice_number: invoice_number).to_xml
  end

  def random_nip
    loop do
      digits = [rand(1..9)] + Array.new(8) { rand(10) }
      check = Ksef::Nip::WEIGHTS.each_with_index.sum { |weight, i| weight * digits[i] } % 11
      nip = (digits + [check]).join
      return nip if check < 10 && Ksef::Nip.new(nip).valid?
    end
  end
end

exit(LiveCheck.new(ARGV[0]).run)
