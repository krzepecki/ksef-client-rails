# frozen_string_literal: true

# Limits in force for the current context and subject, and the API rate limits.
class LimitsController < ApplicationController
  def index; end

  def show
    ksef_action("Limits") do
      limits = authed_client.limits
      { "context (sessions)" => limits.context, "subject (certificates)" => limits.subject,
        "API rate limits" => limits.rate_limits }
    end
  end
end
