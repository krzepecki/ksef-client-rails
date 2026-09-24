# frozen_string_literal: true

# Base controller: the gem configuration and tokens live in the (server-side) session, every page
# builds its `Ksef::Client` from them, and every KSeF call goes through `ksef_action`.
class ApplicationController < ActionController::Base
  # Several forms have extra submit buttons with `formaction` (preview, enrollment data…); per-form
  # CSRF tokens are bound to the form's own action and would reject those submissions with 422.
  self.per_form_csrf_tokens = false

  before_action :verify_page_context, unless: -> { request.get? || request.head? }

  DEFAULT_SETTINGS = {
    "environment" => "test", "timeout" => 30, "nip" => "5555555555", "enforce_xades" => false
  }.freeze

  # Error fields worth printing when present; `response body` carries KSeF's `status.details`.
  ERROR_FIELDS = {
    "codes" => :codes, "HTTP status" => :status, "status.code" => :code, "retry after" => :retry_after,
    "details" => :details, "validator messages" => :messages, "response body" => :body
  }.freeze

  # Blobs above this size go to a file: the memory store (64 MB) also holds the sessions.
  BLOB_MEMORY_LIMIT = 8 * 1024 * 1024
  BLOB_TTL = 30.minutes

  # The result of one demo action, rendered by `shared/_outcome`.
  Outcome = Struct.new(:title, :result, :error, :duration_ms, keyword_init: true)

  # Raised when an action needs an access token and there is none in the session.
  class NotAuthenticated < StandardError
    def initialize(msg = "This action needs an access token — authenticate first (Authentication page).")
      super
    end
  end

  helper_method :settings, :authenticated?, :ksef_config, :access_token_valid_until, :test_environment?,
                :describe_error, :page_context

  private

  # @return [Hash] the session-held configuration and tokens
  def settings
    session[:ksef] ||= DEFAULT_SETTINGS.dup
  end

  def authenticated?
    settings["access_token"].present?
  end

  # The environment and context NIP a page is rendered for; every form sends it back (`ApplicationHelper#token_tag`).
  def page_context
    "#{settings['environment']}:#{settings['nip']}"
  end

  # All tabs share one session, and a long request in one tab writes back the settings it started with:
  # a form from a page that showed another environment or NIP is refused rather than sent there.
  def verify_page_context
    return if params[:page_context] == page_context

    @shown_context = context_label(params[:page_context])
    @current_context = context_label(page_context)
    render "shared/context_changed", status: :conflict
  end

  def context_label(context)
    environment, nip = context.to_s.split(":", 2)
    environment.present? ? "#{environment.upcase} · NIP #{nip}" : "an unknown environment"
  end

  def test_environment?
    settings["environment"] != "prod"
  end

  def access_token_valid_until
    Time.zone.parse(settings["access_valid_until"].to_s) if settings["access_valid_until"].present?
  end

  def ksef_config
    @ksef_config ||= Ksef::Configuration.new(environment: settings["environment"]).tap do |cfg|
      cfg.timeout = settings["timeout"].to_i
      cfg.enforce_xades_compliance! if settings["enforce_xades"]
    end
  end

  def ksef_client
    @ksef_client ||= Ksef::Client.new(access_token: settings["access_token"], config: ksef_config)
  end

  # A client for endpoints that need an access token — fails early with a readable message.
  def authed_client
    raise NotAuthenticated unless authenticated?

    ksef_client
  end

  # Stores tokens from `Ksef::Auth::Coordinator::Result` in the session.
  def store_tokens(result, method:)
    settings.merge!(
      "access_token" => result.access_token, "access_valid_until" => result.access_token_valid_until,
      "refresh_token" => result.refresh_token, "refresh_valid_until" => result.refresh_token_valid_until,
      "auth_reference" => result.reference_number, "auth_method" => method
    )
  end

  # Runs one KSeF call, records its result or error and renders `template`.
  # @param title [String] shown above the result
  # @yieldreturn [Object] the result to display (Hash, Array, String)
  def ksef_action(title, template: :index)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @outcome = Outcome.new(title: title)
    begin
      @outcome.result = yield
    rescue StandardError => e
      @outcome.error = describe_error(e)
    end
    @outcome.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    render template unless performed?
  end

  def describe_error(error)
    out = { "type" => error.class.name, "message" => error.message }
    return out unless error.is_a?(Ksef::Error)

    ERROR_FIELDS.each_with_object(out) do |(label, reader), acc|
      next unless error.respond_to?(reader)

      value = error.public_send(reader)
      acc[label] = value unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end

  def uploaded(name)
    file = params[name]
    file.read if file.respond_to?(:read)
  end

  # Sends a file to the browser (UPO, invoice XML, certificates, export packages).
  def deliver(data, filename, type: "application/xml")
    send_data data, filename: filename, type: type, disposition: "attachment"
  end

  # Holds a generated blob (export package, private key) for `overview#download`, without a database:
  # in memory, or a large one in `tmp/downloads/`. Only the browser session that created it can download it.
  # @return [String] the path to download it from
  def stash(data, filename:, type: "application/octet-stream")
    id = SecureRandom.hex(12)
    blob = { filename: filename, type: type }
    if data.bytesize > BLOB_MEMORY_LIMIT
      blob[:path] = spill(id, data)
    else
      blob[:data] = data
    end
    Rails.cache.write("blob/#{id}", blob, expires_in: BLOB_TTL)
    session[:blob_ids] = (Array(session[:blob_ids]) << id).last(20)
    blob_download_path(id)
  end

  # Writes a large blob to a file and removes the expired ones.
  # @return [String] the file path
  def spill(id, data)
    dir = Rails.root.join("tmp/downloads")
    FileUtils.mkdir_p(dir)
    dir.glob("*").each { |file| file.delete if file.mtime < BLOB_TTL.ago }
    dir.join(id).tap { |path| path.binwrite(data) }.to_s
  end

  # The invoice on the Issue invoice page: the last form previewed or sent (with a fresh demo number), or the sample.
  # @return [InvoiceDraft]
  def saved_draft
    return InvoiceDraft.sample(seller_nip: settings["nip"], full: true) if session[:draft].blank?

    InvoiceDraft.from_params(session[:draft], seller_nip: settings["nip"]).tap do |draft|
      draft.number = InvoiceDraft.demo_number if draft.number.to_s.start_with?("FV/DEMO/")
    end
  end

  # @return [String, nil] the document of the "XML"/"All fields" tab, when that tab was used last
  def saved_invoice_xml
    session[:invoice_xml].presence if %w[schema xml].include?(session[:invoice_tab])
  end

  # A date form field as an explicit Europe/Warsaw timestamp — the API does not define how a
  # date-time without an offset is read.
  # @return [String] e.g. "2026-05-01T00:00:00+02:00"
  def warsaw_time(date, time)
    ActiveSupport::TimeZone["Europe/Warsaw"].parse("#{date} #{time}").iso8601
  end
end
