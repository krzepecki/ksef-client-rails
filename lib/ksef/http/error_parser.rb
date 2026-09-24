# frozen_string_literal: true

module Ksef
  module Http
    # Parses both KSeF error formats — legacy `exception.exceptionDetailList[]` and RFC 7807
    # problem-details — regardless of the X-Error-Format header sent, then maps the HTTP status
    # (and a few business codes) onto an exception class.
    module ErrorParser
      # Business codes of a 400 that deserve their own class. 21308 (a deceased person's credentials) stays
      # a plain BadRequest: authenticating again does not help.
      CODE_CLASSES = {
        21_184 => SessionUnavailable,
        21_301 => ReauthenticationRequired,
        21_304 => ReauthenticationRequired
      }.freeze
      # Longest excerpt of a non-JSON body kept in an error message.
      EXCERPT_LENGTH = 300

      module_function

      # Builds the appropriate {Ksef::ApiError} (or subclass) from the response.
      #
      # @param status [Integer] HTTP code
      # @param body [Object, String, nil] parsed or raw response body
      # @param headers [Hash] response headers (for Retry-After)
      # @return [Ksef::ApiError]
      def build_error(status:, body:, headers: {})
        parsed = coerce_body(body)
        info = extract(parsed)
        klass = error_class_for(status, info[:codes])

        kwargs = {
          status: status,
          codes: info[:codes],
          trace_id: info[:trace_id],
          details: info[:details],
          body: parsed
        }

        if klass == RateLimited
          kwargs[:retry_after] = retry_after_seconds(headers)
          return RateLimited.new(info[:message], **kwargs)
        end

        klass.new(info[:message], **kwargs)
      end

      # Extracts the common fields (message, codes, trace_id, details) from both formats.
      # @return [Hash]
      def extract(body)
        return empty_info unless body.is_a?(Hash)

        from_legacy(body) || from_problem_details(body) || from_flat(body) || empty_info
      end

      # @param status [Integer] HTTP code
      # @param codes [Array<Integer>] business codes from the body
      # @return [Class] exception class for the HTTP code (a code-specific class for a 400 when one exists)
      def error_class_for(status, codes = [])
        base = status_class(status)
        return base unless status == 400

        codes.each do |code|
          specific = CODE_CLASSES[code]
          return specific if specific
        end
        base
      end

      def status_class(status)
        case status
        when 400 then BadRequest
        when 401 then Unauthorized
        when 403 then Forbidden
        when 404 then NotFound
        when 409 then Conflict
        when 410 then Gone
        when 429 then RateLimited
        when 500..599 then ServerError
        else ApiError
        end
      end

      # --- legacy format: exception.exceptionDetailList[] ---------------------------------
      def from_legacy(body)
        exception = body["exception"] || body[:exception]
        return nil unless exception.is_a?(Hash)

        list = Array(exception["exceptionDetailList"] || exception["ExceptionDetailList"]).grep(Hash)
        codes = list.map { |d| int_or_nil(d["exceptionCode"] || d["ExceptionCode"]) }.compact
        messages = list.map { |d| d["exceptionDescription"] || d["ExceptionDescription"] }.compact
        {
          message: messages.first || exception["exceptionType"],
          codes: codes,
          trace_id: exception["referenceNumber"] || exception["ReferenceNumber"] || exception["serviceCode"],
          details: list
        }
      end

      # --- RFC 7807 format: title/status/errors[] ----------------------------------------
      def from_problem_details(body)
        return nil unless body.key?("title") || body.key?("detail") || body.key?("errors")

        errors = body["errors"] || []
        errors = errors.values.flatten if errors.is_a?(Hash) # the { "field": ["msg"] } variant
        codes = Array(errors).map { |e| e.is_a?(Hash) ? int_or_nil(e["code"]) : nil }.compact
        message = body["detail"] || body["title"]
        message = "#{message} (#{body['reasonCode']})" if body["reasonCode"] # 403: why access was denied
        message = [message, *Array(errors).filter_map { |e| error_text(e) }].compact.join(" — ")
        {
          message: message,
          codes: codes,
          trace_id: body["traceId"] || body["trace_id"],
          details: Array(errors)
        }
      end

      # --- flat format: { code:, message: } or { status: { code:, description:, details: } } ---
      def from_flat(body)
        status = body["status"]
        if status.is_a?(Hash) # the legacy 429 TooManyRequestsResponse
          return {
            message: status["description"],
            codes: [int_or_nil(status["code"])].compact,
            trace_id: body["traceId"],
            details: Array(status["details"])
          }
        end
        if body["message"] || body["code"]
          return {
            message: body["message"],
            codes: [int_or_nil(body["code"])].compact,
            trace_id: body["traceId"],
            details: [body]
          }
        end
        nil
      end

      def empty_info
        { message: nil, codes: [], trace_id: nil, details: [] }
      end

      # "Błąd walidacji danych wejściowych. (Wskazany kod formularza nie jest wspierany.)" — the
      # problem-details `detail` alone is generic ("Żądanie jest nieprawidłowe.").
      def error_text(error)
        return error if error.is_a?(String) # the { "field": ["message"] } variant
        return nil unless error.is_a?(Hash) && error["description"]

        details = Array(error["details"]).join("; ")
        details.empty? ? error["description"] : "#{error['description']} (#{details})"
      end

      def coerce_body(body)
        return body unless body.is_a?(String)
        return nil if body.strip.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        { "message" => excerpt(body) }
      end

      # A non-JSON body (an HTML gateway page, say) as a short UTF-8 string: bodies without a charset
      # arrive as BINARY, and a whole page in an exception message helps no one.
      # @param body [String]
      # @return [String]
      def excerpt(body)
        text = body.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").gsub(/\s+/, " ").strip
        text.length > EXCERPT_LENGTH ? "#{text[0, EXCERPT_LENGTH]}…" : text
      end

      def retry_after_seconds(headers)
        raw = header_value(headers, "Retry-After")
        return nil if raw.nil? || raw.to_s.strip.empty?

        Integer(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def header_value(headers, name)
        return nil unless headers

        headers[name] || headers[name.downcase] || headers[name.upcase]
      end

      def int_or_nil(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
