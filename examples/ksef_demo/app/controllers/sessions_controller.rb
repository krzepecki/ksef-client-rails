# frozen_string_literal: true

# Online and batch sessions: list, status with invoice counters, the invoices (accepted and
# rejected, with `status.details`) and UPO downloads.
class SessionsController < ApplicationController
  def index
    return unless authenticated?

    ksef_action("Sessions") do
      @sessions = ksef_client.sessions.list(session_type: params[:type].presence_in(%w[Online Batch]) || "Online")
                             .first(30)
      nil
    end
  end

  def show
    ksef_action("Session #{params[:reference]}", template: :show) do
      client = authed_client
      @status = client.sessions.status(params[:reference])
      @invoices = client.sessions.invoices(params[:reference]).first(100)
      if @status["failedInvoiceCount"].to_i.positive?
        @failed = client.sessions.failed_invoices(params[:reference]).first(100)
      end
      nil
    end
  end

  def invoice_upo
    upo = authed_client.sessions.invoice_upo(params[:reference], params[:invoice])
    deliver(upo, "UPO-#{params[:invoice]}.xml")
  rescue StandardError => e
    redirect_to session_path(params[:reference]), alert: "UPO download failed: #{e.message}"
  end

  def session_upo
    upo = authed_client.sessions.session_upo(params[:reference], params[:upo])
    deliver(upo, "UPO-session-#{params[:upo]}.xml")
  rescue StandardError => e
    redirect_to session_path(params[:reference]), alert: "UPO download failed: #{e.message}"
  end
end
