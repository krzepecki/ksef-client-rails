# frozen_string_literal: true

module Ksef
  module Resources
    # Effective limits resource — /limits/* and /rate-limits endpoints.
    #
    # Returns the session/certificate limits currently in force and the API rate limits for the
    # current context. Every endpoint requires an accessToken.
    class Limits < Base
      CONTEXT = "/limits/context"
      SUBJECT = "/limits/subject"
      RATE_LIMITS = "/rate-limits"

      # GET /limits/context — online/batch session limits for the current context.
      # @return [Hash] { "onlineSession" => {...}, "batchSession" => {...} }
      def context
        get(CONTEXT, returns: [])
      end

      # GET /limits/subject — request and certificate limits for the current subject.
      # @return [Hash] { "enrollment" => {...}, "certificate" => {...} }
      def subject
        get(SUBJECT, returns: [])
      end

      # GET /rate-limits — effective API rate limits per operation.
      # @return [Hash] limits per operation (including "onlineSession", "invoiceSend", ...)
      def rate_limits
        get(RATE_LIMITS, returns: [])
      end
    end
  end
end
