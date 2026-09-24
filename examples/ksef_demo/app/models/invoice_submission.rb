# frozen_string_literal: true

# Sends one invoice through an online session and records every step (status, duration, detail),
# so the page can draw a timeline — including which step failed and why.
class InvoiceSubmission
  Step = Struct.new(:key, :label, :status, :duration_ms, :detail, keyword_init: true)

  STEPS = {
    validate: "Validate against the FA(3) schema",
    open: "Open an online session (AES key wrapped with RSA-OAEP)",
    send: "Encrypt and send the invoice",
    close: "Close the session",
    upo: "Wait for processing and download the UPO",
    status: "Read the assigned KSeF number"
  }.freeze

  POLL = { interval: 2, timeout: 90 }.freeze

  attr_reader :xml, :steps, :error, :session_reference, :invoice_reference, :invoice_hash, :upo, :ksef_number

  # @param client [Ksef::Client] authenticated client
  # @param xml [String] invoice XML
  # @param validate [Boolean] false sends without the local XSD check (to see KSeF's own rejection)
  def initialize(client, xml, validate: true)
    @client = client
    @xml = xml
    @validate = validate
    @steps = STEPS.map { |key, label| Step.new(key: key, label: label, status: :pending) }
  end

  # @return [self]
  def call
    step(:validate) { validate }
    session = step(:open) { open_session }
    send_or_close(session)
    step(:close) do
      session.close
      "Closed — KSeF now finalises the invoices"
    end
    step(:upo) { @upo = session.wait_for_upo(invoice_reference, poll: POLL) }
    step(:status) { @ksef_number = @client.sessions.invoice(session_reference, invoice_reference)["ksefNumber"] }
    self
  rescue StandardError => e
    @error = e
    self
  end

  def success?
    error.nil?
  end

  def failed_step
    steps.find { |s| s.status == :failed }
  end

  # Whether KSeF may still accept the invoice: the send broke off in transit (a timeout or dropped
  # connection), or it was sent and closing or waiting for the UPO failed with anything but a rejection.
  def outcome_unknown?
    case failed_step&.key
    when :send then error.is_a?(Ksef::NetworkError)
    when :close, :upo then !error.is_a?(Ksef::InvoiceRejected)
    else false
    end
  end

  private

  def step(key)
    current = steps.find { |s| s.key == key }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    current.status = :running
    value = yield
    current.status = :done
    current.detail = describe(key, value)
    value
  rescue StandardError
    current.status = :failed
    raise
  ensure
    current.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end

  def validate
    return "Skipped — sent as-is" unless @validate

    Ksef::Invoices::Validator.new(form_code: Ksef::FormCode::FA3).validate!(xml)
    "Valid FA(3) document"
  end

  def open_session
    Ksef::Sessions::Online.open(@client, form_code: Ksef::FormCode::FA3).tap do |session|
      @session_reference = session.reference_number
    end
  end

  # A failed send still closes the session (best effort) rather than leaving it open until KSeF expires it.
  def send_or_close(session)
    step(:send) { send_invoice(session) }
  rescue StandardError
    close_after_failure(session)
    raise
  end

  def close_after_failure(session)
    step(:close) do
      session.close
      "Closed after the failed send"
    end
  rescue StandardError => e
    steps.find { |s| s.key == :close }.detail = "Not closed: #{e.message}"
  end

  def send_invoice(session)
    sent = session.send_invoice(xml)
    @invoice_reference = sent.reference_number
    @invoice_hash = sent.invoice_metadata.hash_sha
    sent
  end

  def describe(key, value)
    case key
    when :open then "Session #{value.reference_number}"
    when :send then "Invoice #{invoice_reference} · #{value.invoice_metadata.size} B plain, " \
                    "#{value.encrypted_metadata.size} B encrypted"
    when :upo then "UPO received (#{value.bytesize} B)"
    when :status then "KSeF number #{value}"
    else value.to_s
    end
  end
end
