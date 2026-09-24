# frozen_string_literal: true

module Ksef
  # Base error of the gem; every error below inherits from it.
  #
  # 450/460/470/480/550 are NOT HTTP codes — they are `status.code` values inside an HTTP 200
  # body, hence AuthenticationFailed is a separate branch rather than an ApiError subclass.
  class Error < StandardError; end

  # Invalid gem configuration detected locally (e.g. missing environment, bad base_url).
  class ConfigurationError < Error; end

  # Cryptography / XAdES signature layer error (e.g. no private key in the certificate).
  class CryptoError < Error; end

  # Error returned by the API as an HTTP 4xx/5xx response. {Ksef::Http::ErrorParser} fills the
  # attributes from either response format (legacy `exceptionDetailList[]` or RFC 7807).
  class ApiError < Error
    # @return [Integer, nil] HTTP status code (e.g. 400, 429)
    attr_reader :status
    # @return [Array<Integer>] business error codes from the body (e.g. [21402])
    attr_reader :codes
    # @return [String, nil] trace identifier (trace_id / traceId), when returned
    attr_reader :trace_id
    # @return [Array<Hash>] raw error entries (for diagnostics)
    attr_reader :details
    # @return [Object, nil] raw parsed response body
    attr_reader :body

    # @param message [String, nil] human-readable message
    # @param status [Integer, nil] HTTP code
    # @param codes [Array<Integer>] business error codes
    # @param trace_id [String, nil]
    # @param details [Array<Hash>] raw error entries
    # @param body [Object, nil] raw response body
    def initialize(message = nil, status: nil, codes: [], trace_id: nil, details: [], body: nil)
      @status = status
      @codes = Array(codes)
      @trace_id = trace_id
      @details = Array(details)
      @body = body
      super(build_message(message))
    end

    private

    def build_message(message)
      parts = []
      parts << "HTTP #{status}" if status
      parts << (message || "KSeF API error")
      parts << "codes: #{codes.join(', ')}" unless codes.empty?
      parts << "trace_id: #{trace_id}" if trace_id
      parts.join(" | ")
    end
  end

  # 400 — invalid request (validation, wrong schema, wrong invoice sizes/hashes).
  class BadRequest < ApiError; end

  # 400 with code 21184 — the session is under maintenance. Retry later, or open a new session and
  # send the remaining invoices there.
  class SessionUnavailable < BadRequest; end

  # The authentication can no longer be used — authenticate again: a 400 with code 21301 (the
  # authentication does not allow it, e.g. its KSeF token was revoked) or 21304 (the authentication
  # operation does not exist — also from the auth status), or a 401 from the token refresh (the refresh
  # token expired or was revoked).
  class ReauthenticationRequired < ApiError; end

  # 401 — missing/invalid authentication token, or the token expired.
  class Unauthorized < ApiError; end

  # 403 — no permission for the resource in the given context.
  class Forbidden < ApiError; end

  # 404 — resource does not exist.
  class NotFound < ApiError; end

  # 410 — resource expired (retention: auth/export 7 days, enrollment/permissions 30 days).
  class Gone < ApiError; end

  # 409 — conflict (e.g. the operation was already performed).
  class Conflict < ApiError; end

  # 429 — request limit exceeded. Carries `retry_after` (seconds) from the Retry-After header.
  class RateLimited < ApiError
    # @return [Integer, nil] seconds until a retry is allowed (from the Retry-After header)
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **)
      @retry_after = retry_after
      super(message, **)
    end
  end

  # 5xx — server-side error.
  class ServerError < ApiError; end

  # KSeF rejected an invoice: a `status.code` of 400 or more in the invoice status (an HTTP 200 body), so
  # `#status` is nil and the code is in `#codes` (440 — a duplicate); `#body` is that status. Any other
  # ApiError from waiting for the UPO is not a rejection — the invoice may already be accepted.
  class InvoiceRejected < ApiError; end

  # Transport failure (DNS, refused connection, TLS, timeout, a dropped connection) once the allowed
  # retries are spent; the original Faraday exception is the #cause. For a call that is not idempotent
  # (e.g. sending an invoice) a failure after the request was written — a reset, a dropped or cut-short
  # response — leaves the outcome unknown, as a {RequestTimeout} does: check the status before sending it
  # again.
  class NetworkError < Error; end

  # The request timed out waiting for the response. For a call that is not idempotent the outcome is
  # unknown — check the status before sending it again. (A request that never left the process, such
  # as a connect timeout, is a plain {NetworkError}.)
  class RequestTimeout < NetworkError; end

  # A batch upload failed after the session was declared — a part upload, or closing the session. The
  # reference number names the session to check (and close again) before uploading anew.
  class BatchUploadError < Error
    # @return [String, nil] batch session reference number
    attr_reader :reference_number
    # @return [Integer, nil] ordinal number of the part that failed (nil when closing failed)
    attr_reader :ordinal_number

    def initialize(message = nil, reference_number: nil, ordinal_number: nil)
      @reference_number = reference_number
      @ordinal_number = ordinal_number
      super([message, ("session: #{reference_number}" if reference_number)].compact.join(" | "))
    end
  end

  # Auth failed — `status.code` from the polling body signalled an error (450 invalid token,
  # 460 certificate, 470 deceased person, 480 blocked, 425 revoked, 415 no permissions, 550 cancelled).
  class AuthenticationFailed < Error
    # @return [Integer, nil] the status.code value from the response body (e.g. 450)
    attr_reader :code
    # @return [Array<String>] detailed messages (status.details)
    attr_reader :messages

    def initialize(message = nil, code: nil, messages: [])
      @code = code
      @messages = Array(messages)
      super([message, "status.code=#{code}", *messages].compact.join(" | "))
    end
  end

  # Invoice failed local validation ({Ksef::Invoices::Validator}): the XSD or KSeF's XML rules, which KSeF
  # would reject too (in libxml2's wording).
  class SchemaValidationError < Error
    # @return [Array<String>] XSD validator messages
    attr_reader :messages
    # @return [Array<Ksef::Invoices::Validator::Issue>] the same violations with element path and line
    attr_reader :errors
    # @return [String, nil] form systemCode (e.g. "FA (3)")
    attr_reader :system_code

    def initialize(message = nil, messages: [], errors: [], system_code: nil)
      @messages = Array(messages)
      @errors = Array(errors)
      @system_code = system_code
      super([message, *@messages].compact.join(" | "))
    end
  end

  # A metadata query reached KSeF's 10,000-record limit (`hasMore` and `isTruncated`): the rest is
  # fetched with a narrower `dateRange` bounded by the last record's date — `from` when sorted ascending,
  # `to` when descending.
  class ResultTruncated < Error
    # @return [Hash, nil] the last record returned — its date is where the next query starts
    attr_reader :last_item

    def initialize(message = nil, last_item: nil)
      @last_item = last_item
      super(message)
    end
  end

  # Async operation (auth, session, export, enrollment, permissions) exceeded its wait limit.
  class PollingTimeout < Error
    # @return [String, nil] last known status of the operation
    attr_reader :last_status

    def initialize(message = nil, last_status: nil)
      @last_status = last_status
      super([message, ("last status: #{last_status}" if last_status)].compact.join(" | "))
    end
  end
end
