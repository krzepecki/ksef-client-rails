# frozen_string_literal: true

module Ksef
  module Resources
    # Test data resource — /testdata/* endpoints, refused locally on PROD. Setup (entities, persons,
    # permissions, attachments) and context blocking are anonymous; the limits and certificate
    # updates act on the authenticated context and need an accessToken. Bodies pass through as-is.
    class TestData < Base
      SUBJECT = "/testdata/subject"
      SUBJECT_REMOVE = "/testdata/subject/remove"
      PERSON = "/testdata/person"
      PERSON_REMOVE = "/testdata/person/remove"
      PERMISSIONS = "/testdata/permissions"
      PERMISSIONS_REVOKE = "/testdata/permissions/revoke"
      ATTACHMENT = "/testdata/attachment"
      ATTACHMENT_REVOKE = "/testdata/attachment/revoke"
      CONTEXT_BLOCK = "/testdata/context/block"
      CONTEXT_UNBLOCK = "/testdata/context/unblock"
      SESSION_LIMITS = "/testdata/limits/context/session"
      CERTIFICATE_LIMITS = "/testdata/limits/subject/certificate"
      RATE_LIMITS = "/testdata/rate-limits"
      RATE_LIMITS_PRODUCTION = "/testdata/rate-limits/production"

      # POST /testdata/subject — creates a test entity. Anonymous.
      # @param body [Hash] SubjectCreateRequest
      # @return [nil]
      def create_subject(body:)
        post(SUBJECT, bearer: nil, json: body)
      end

      # POST /testdata/subject/remove — removes a test entity. Anonymous.
      # @param body [Hash] SubjectRemoveRequest
      # @return [nil]
      def remove_subject(body:)
        post(SUBJECT_REMOVE, bearer: nil, json: body)
      end

      # POST /testdata/person — creates a test person. Anonymous.
      # @param body [Hash] PersonCreateRequest
      # @return [nil]
      def create_person(body:)
        post(PERSON, bearer: nil, json: body)
      end

      # POST /testdata/person/remove — removes a test person. Anonymous.
      # @param body [Hash] PersonRemoveRequest
      # @return [nil]
      def remove_person(body:)
        post(PERSON_REMOVE, bearer: nil, json: body)
      end

      # POST /testdata/permissions — grants test permissions. Anonymous.
      # @param body [Hash] TestDataPermissionsGrantRequest
      # @return [nil]
      def grant_permissions(body:)
        post(PERMISSIONS, bearer: nil, json: body)
      end

      # POST /testdata/permissions/revoke — revokes test permissions. Anonymous.
      # @param body [Hash] TestDataPermissionsRevokeRequest
      # @return [nil]
      def revoke_permissions(body:)
        post(PERMISSIONS_REVOKE, bearer: nil, json: body)
      end

      # POST /testdata/attachment — enables attachment support. Anonymous.
      # @param body [Hash] AttachmentPermissionGrantRequest
      # @return [nil]
      def enable_attachment(body:)
        post(ATTACHMENT, bearer: nil, json: body)
      end

      # POST /testdata/attachment/revoke — disables attachment support. Anonymous.
      # @param body [Hash] AttachmentPermissionRevokeRequest
      # @return [nil]
      def disable_attachment(body:)
        post(ATTACHMENT_REVOKE, bearer: nil, json: body)
      end

      # POST /testdata/context/block — blocks authentication for the context (it then fails with 480).
      # Anonymous.
      # @param body [Hash] BlockContextAuthenticationRequest: { "contextIdentifier" => { "type", "value" } }
      # @return [nil]
      def block_context(body:)
        post(CONTEXT_BLOCK, bearer: nil, json: body)
      end

      # POST /testdata/context/unblock — unblocks authentication for the context. Anonymous.
      # @param body [Hash] UnblockContextAuthenticationRequest: { "contextIdentifier" => { "type", "value" } }
      # @return [nil]
      def unblock_context(body:)
        post(CONTEXT_UNBLOCK, bearer: nil, json: body)
      end

      # POST /testdata/limits/context/session — sets session limits for the context. Bearer: accessToken.
      # @param body [Hash] SetSessionLimitsRequest (it also requires
      #   "collectiveIdentifier" => { "maxInvoices" => n })
      # @return [nil]
      def set_session_limits(body:)
        post(SESSION_LIMITS, json: body)
      end

      # DELETE /testdata/limits/context/session — restores the default session limits. Bearer: accessToken.
      # @return [nil]
      def reset_session_limits
        delete(SESSION_LIMITS)
      end

      # POST /testdata/limits/subject/certificate — sets the subject certificate limits. Bearer: accessToken.
      # @param body [Hash] SetSubjectLimitsRequest
      # @return [nil]
      def set_certificate_limits(body:)
        post(CERTIFICATE_LIMITS, json: body)
      end

      # DELETE /testdata/limits/subject/certificate — restores the default certificate limits. Bearer: accessToken.
      # @return [nil]
      def reset_certificate_limits
        delete(CERTIFICATE_LIMITS)
      end

      # POST /testdata/rate-limits — sets the API rate limits for the context. Bearer: accessToken.
      # @param body [Hash] SetRateLimitsRequest ("rateLimits" also requires
      #   "collectiveIdentifier" => { "perSecond", "perMinute", "perHour" })
      # @return [nil]
      def set_rate_limits(body:)
        post(RATE_LIMITS, json: body)
      end

      # DELETE /testdata/rate-limits — restores the default API rate limits. Bearer: accessToken.
      # @return [nil]
      def reset_rate_limits
        delete(RATE_LIMITS)
      end

      # POST /testdata/rate-limits/production — sets rate limits matching the production profile.
      # Bearer: accessToken.
      # @return [nil]
      def set_production_rate_limits
        post(RATE_LIMITS_PRODUCTION, json: {})
      end

      # PUT /testdata/certificates/{serialNumber} — shortens the validity of one of the subject's KSeF
      # certificates. Bearer: accessToken.
      # @param serial_number [String] 16 hex digits
      # @param valid_to [String] new end of validity (ISO 8601), not later than the current one
      # @return [nil]
      def update_certificate(serial_number, valid_to:)
        put(path("testdata", "certificates", serial_number), json: { "validTo" => valid_to })
      end

      private

      def post(...)
        ensure_not_production!
        super
      end

      def delete(...)
        ensure_not_production!
        super
      end

      def put(...)
        ensure_not_production!
        super
      end

      # By the label and by the host the requests go to (an api_base_url_override may point anywhere).
      def ensure_not_production!
        prod_host = URI(Environments::PROD.api_base_url).host
        return unless config.environment == :prod || URI(connection.base_url).host == prod_host

        raise ConfigurationError, "/testdata endpoints do not exist on the production environment"
      end
    end
  end
end
