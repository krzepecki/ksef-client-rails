# frozen_string_literal: true

# Configuration (environment, timeout, context NIP, XAdES enforcement) and the anonymous
# connectivity check — the best first test of an environment.
class OverviewController < ApplicationController
  ENVIRONMENTS = %w[test demo prod].freeze

  def index; end

  def update
    nip = Ksef::Nip.new(params[:nip].to_s.strip.presence || DEFAULT_SETTINGS["nip"])
    unless nip.valid?
      return redirect_to root_path, alert: "#{params[:nip].to_s.strip.inspect} is not a valid NIP (10 digits with a " \
                                           "valid check digit) — nothing was saved."
    end

    env = params[:environment].presence_in(ENVIRONMENTS) || "test"
    # Tokens are bound to one environment — switching it signs you out.
    session[:ksef] = DEFAULT_SETTINGS.dup if env != settings["environment"]
    settings.merge!(
      "environment" => env, "timeout" => params[:timeout].to_i.clamp(5, 300), "nip" => nip.value,
      "enforce_xades" => params[:enforce_xades] == "1"
    )
    redirect_to root_path, notice: "Settings saved."
  end

  def check_connection
    ksef_action("Check connection") do
      certs = ksef_client.security.public_key_certificates
      { "API" => ksef_config.api_url, "certificates" => certs.map do |c|
        c.slice("publicKeyId", "usage", "validFrom", "validTo")
      end }
    end
  end

  # Serves a blob held by `stash` (export packages, generated keys) to the session that created it.
  def download
    blob = Rails.cache.read("blob/#{params[:id]}") if Array(session[:blob_ids]).include?(params[:id])
    unless blob && (blob[:data] || File.file?(blob[:path].to_s))
      return redirect_back(fallback_location: root_path, alert: "That download has expired.")
    end

    options = { filename: blob[:filename], type: blob[:type] || "application/octet-stream" }
    blob[:path] ? send_file(blob[:path], **options) : send_data(blob[:data], **options)
  end
end
