# frozen_string_literal: true

# Authentication: KSeF token or XAdES certificate signature, token refresh, pasted tokens and the
# list of authentication sessions. Tokens land in the session and every other page uses them.
class AuthController < ApplicationController
  POLL = { interval: 2, timeout: 90 }.freeze

  def index; end

  def token
    ksef_action("Authenticate with a KSeF token") do
      result = Ksef::Auth::Coordinator.new(ksef_client).authenticate_with_token(
        context: { nip: settings["nip"] }, token: params[:ksef_token].to_s.strip, poll: POLL
      )
      store_tokens(result, method: "KSeF token")
      token_summary(result)
    end
  end

  # challenge → XAdES-signed AuthTokenRequest → polling. Self-signed certificates work on TEST only.
  def certificate
    ksef_action("Authenticate with a certificate (XAdES)") do
      upload = CertificateUpload.new(certificate: uploaded(:certificate_file), key: uploaded(:key_file),
                                     password: params[:certificate_password].to_s)
      cert, key = upload.certificate_and_key
      @certificate_info = upload.info
      result = Ksef::Auth::Coordinator.new(ksef_client).authenticate(
        context: { nip: settings["nip"] }, signer: capture_signature(cert, key),
        subject_identifier_type: subject_identifier_type,
        verify_certificate_chain: params[:verify_chain] == "1", poll: POLL
      )
      store_tokens(result, method: "XAdES certificate")
      token_summary(result)
    end
  end

  def refresh
    ksef_action("Refresh the access token") do
      if settings["refresh_token"].blank?
        raise NotAuthenticated,
              "No refresh token in the session — authenticate first."
      end

      response = Ksef::Auth::Coordinator.new(ksef_client).refresh(refresh_token: settings["refresh_token"])
      settings.merge!("access_token" => response.dig("accessToken", "token"),
                      "access_valid_until" => response.dig("accessToken", "validUntil"))
      { "access token valid until" => response.dig("accessToken", "validUntil") }
    end
  end

  # Tokens pasted by hand (e.g. from another tool).
  def manual
    settings.merge!("access_token" => params[:access_token].to_s.strip.presence,
                    "refresh_token" => params[:refresh_token].to_s.strip.presence,
                    "access_valid_until" => nil, "auth_method" => "pasted")
    redirect_to auth_path(tab: "manual"), notice: "Tokens saved."
  end

  def list_sessions
    ksef_action("Authentication sessions") do
      @auth_sessions = authed_client.auth.sessions.first(50)
      { "active sessions" => @auth_sessions.size }
    end
  end

  def revoke
    ksef_action("Revoke authentication session") do
      authed_client.auth.revoke_session(params[:reference])
      { "revoked" => params[:reference] }
    end
  end

  # Revokes the current auth session in KSeF (best effort) and forgets the tokens locally.
  def logout
    token = settings["refresh_token"] || settings["access_token"]
    begin
      ksef_client.auth.revoke_current_session(token: token) if token
    rescue Ksef::Error => e
      flash[:alert] = "KSeF did not revoke the session (#{e.message}) — the tokens were forgotten locally anyway."
    end
    settings.except!("access_token", "refresh_token", "access_valid_until", "refresh_valid_until",
                     "auth_reference", "auth_method")
    redirect_to auth_path, notice: flash[:alert] ? nil : "Signed out."
  end

  private

  def subject_identifier_type
    params[:subject_identifier_type].presence_in(%w[certificate_subject certificate_fingerprint])&.to_sym ||
      :certificate_subject
  end

  def token_summary(result)
    {
      "reference number" => result.reference_number,
      "access token valid until" => result.access_token_valid_until,
      "refresh token valid until" => result.refresh_token_valid_until
    }
  end

  # Keeps the exact signed document — a 9105 ("Nieprawidłowy podpis") is only debuggable with it.
  def capture_signature(cert, key)
    signer = Ksef::Xades::Signer.new(cert: cert, key: key)
    ->(xml) { @signed_xml = signer.sign(xml) }
  end
end
