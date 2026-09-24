# frozen_string_literal: true

# KSeF tokens: generate (with permissions), list, check status, revoke.
class TokensController < ApplicationController
  PERMISSIONS = %w[InvoiceRead InvoiceWrite CredentialsRead CredentialsManage SubunitManage EnforcementOperations
                   Introspection CollectiveIdentifierManage].freeze

  def index; end

  def create
    ksef_action("Generate KSeF token") do
      response = authed_client.tokens.generate(permissions: Array(params[:permissions]) & PERMISSIONS,
                                               description: params[:description].to_s)
      @new_token = response["token"]
      { "reference number" => response["referenceNumber"] }
    end
  end

  def list
    ksef_action("KSeF tokens") do
      @tokens = authed_client.tokens.list(status: params[:status].presence && [params[:status]]).first(50)
      { "tokens" => @tokens.size }
    end
  end

  def status
    ksef_action("Token status") { authed_client.tokens.status(params[:reference].to_s.strip) }
  end

  def revoke
    ksef_action("Revoke token") do
      authed_client.tokens.revoke(params[:reference])
      { "revoked" => params[:reference] }
    end
  end
end
