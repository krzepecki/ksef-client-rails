# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"
require "json"
require "openssl"
require "socket"
require "timeout"
require "uri"

module Ksef
  module Http
    # Lightweight response object returned by {Connection}.
    class Response
      # @return [Integer] HTTP code
      attr_reader :status
      # @return [Hash] response headers (keys as produced by Faraday, usually lowercase)
      attr_reader :headers
      # @return [Object, nil] body parsed from JSON (or nil for raw/empty responses)
      attr_reader :body
      # @return [String] raw body (bytes) — useful for binary downloads
      attr_reader :raw_body

      def initialize(status:, headers:, body:, raw_body:)
        @status = status
        @headers = headers
        @body = body
        @raw_body = raw_body
      end

      # @return [Boolean] whether the status is within 2xx
      def success?
        status.between?(200, 299)
      end

      # @param name [String] header name (case-insensitive)
      # @return [String, nil]
      def header(name)
        headers[name] || headers[name.downcase] || headers[name.upcase]
      end
    end

    # Faraday-based HTTP layer: JSON and raw-byte requests, base headers, retries, X-System-Warning
    # logging, errors via {ErrorParser}. Transport failures surface as {Ksef::NetworkError}. Every HTTP
    # attempt is logged at debug level and published as `request.ksef` (ActiveSupport::Notifications).
    #
    # Stateless in tokens: each request carries its own +bearer:+, so accessToken /
    # authenticationToken / refreshToken cannot be confused at the resource level.
    class Connection
      # A body shorter than its Content-Length: the connection dropped mid-response.
      class TruncatedBody < IOError; end

      IDEMPOTENT_METHODS = %i[get head].freeze
      # Presigned URLs address a single blob, so an upload (PUT) can be repeated safely too.
      PRESIGNED_IDEMPOTENT_METHODS = %i[get head put].freeze
      # Statuses worth retrying for an idempotent request (transient server/gateway failures).
      RETRY_STATUSES = [500, 502, 503, 504].freeze
      # Transport failures, retried for an idempotent request. Faraday wraps only some of them; a host
      # or network that is down, a local firewall or a dropped keep-alive socket surface unwrapped.
      TRANSPORT_ERRORS = [Faraday::ConnectionFailed, Faraday::TimeoutError, Timeout::Error, SystemCallError,
                          IOError, SocketError, Net::HTTP::Persistent::Error].freeze
      # TLS failures — never retried.
      TLS_ERRORS = [Faraday::SSLError, OpenSSL::SSL::SSLError].freeze
      # First backoff delay (s) for a retried failure; it doubles with every attempt.
      RETRY_BASE_DELAY = 0.5
      # ActiveSupport::Notifications event, payload `{ method:, path:, status: }` — never a query string,
      # header or body.
      NOTIFICATION = "request.ksef"
      # Content types whose 2xx body is not echoed into an error: it may carry a token.
      JSON_TYPES = %r{\Aapplication/(?:[\w.+-]+\+)?json}i

      @cert_store_lock = Mutex.new

      # The system CA bundle, loaded once per process and shared by every connection: each store holds
      # about 1 MiB that Ruby's GC does not see.
      # @return [OpenSSL::X509::Store]
      def self.default_cert_store
        @cert_store_lock.synchronize do
          @default_cert_store ||= OpenSSL::X509::Store.new.tap(&:set_default_paths)
        end
      end

      # @return [String] the API base URL requests go to
      attr_reader :base_url

      # @param config [Ksef::Configuration]
      # @param base_url [String, nil] base URL override (defaults to config.api_url)
      def initialize(config:, base_url: nil)
        @config = config
        @base_url = base_url || config.api_url
        @faraday = build_faraday
      end

      # Performs the request and returns a {Response}; raises {Ksef::ApiError} on an error status.
      #
      # @param method [Symbol] :get/:post/:delete/:put
      # @param path [String] relative path (appended to base_url) or a full URL (http...)
      # @param bearer [String, #call, nil] token for the Authorization header; a callable is read again for
      #   every attempt, so a retry after a long Retry-After sends the current token
      # @param json [Object, nil] body serialized to JSON
      # @param body [String, nil] raw body (takes precedence over json)
      # @param query [Hash, nil] query parameters (an Array value repeats the key)
      # @param headers [Hash] extra headers
      # @param raw [Boolean, :xml] when true, JSON is not parsed (binary downloads); :xml also refuses a 2xx
      #   body that is not an XML document (an HTML proxy page, an empty body)
      # @param auth [Boolean] when false, neither Authorization nor the base KSeF headers are sent
      # @return [Response]
      # @raise [Ksef::ApiError, Ksef::NetworkError]
      # @raise [Ksef::ConfigurationError] for a token with a control character (CR, LF, …)
      def request(method, path, bearer: nil, json: nil, body: nil, query: nil, headers: {}, raw: false, auth: true)
        opts = { bearer: bearer, json: json, body: body, query: query, headers: headers, raw: raw, auth: auth }
        target = "#{method.to_s.upcase} #{normalize_path(path)}"
        response = with_retries(IDEMPOTENT_METHODS.include?(method), target) do
          observe(method, normalize_path(path)) { run(method, path, **opts) }
        end
        log_system_warning(response)
        raise_on_error(response) unless response.success?
        raise unexpected_body_error(response) if !raw && response.body.is_a?(String)
        raise unexpected_body_error(response, "XML") if raw == :xml && !xml_document?(response)

        response
      end

      def get(path, **)
        request(:get, path, **)
      end

      def post(path, **)
        request(:post, path, **)
      end

      def delete(path, **)
        request(:delete, path, **)
      end

      def put(path, **)
        request(:put, path, **)
      end

      # Closes the keep-alive connections; the next request opens new ones (a request already under way
      # finishes on its own connection).
      # @return [void]
      def close
        old = [@faraday, @presigned_faraday]
        @faraday = build_faraday
        @presigned_faraday = nil
        old.compact.each(&:close)
      end

      # Transfer from/to a presigned URL (a different host — Azure Blob), WITHOUT a token and
      # without KSeF headers. Used to download export parts and upload batch package parts.
      #
      # @param method [Symbol, String] :get/:put/:post
      # @param url [String] full presigned URL
      # @param body [String, nil] raw bytes (for uploads)
      # @param headers [Hash] headers from the server response (method+headers as in the C# pattern)
      # @return [Response]
      # @raise [Ksef::ApiError, Ksef::NetworkError]
      def presigned_transfer(method, url, body: nil, headers: {})
        url = https_url(url)
        verb = method.to_s.downcase.to_sym
        # The URL carries a signature, so the error message names the verb only.
        response = with_retries(PRESIGNED_IDEMPOTENT_METHODS.include?(verb), "presigned #{verb.upcase}") do
          observe(verb, "presigned") do
            build_response(presigned_faraday.run_request(verb, url, body, stringify(headers)), true)
          end
        end
        raise_on_error(response) unless response.success?
        response
      end

      # Keeps a proxy password out of logs, `pp` output and exception reports.
      # @return [String]
      def inspect
        "#<#{self.class.name} base_url=#{@base_url.inspect} adapter=#{@config.adapter.inspect}>"
      end

      private

      # The presigned URL comes from the API response; refusing anything but https keeps a tampered
      # or misconfigured response from moving invoice data onto a plaintext channel. The normalized URL
      # is what gets sent: Faraday reads "HTTPS://…" or "https:host" as a relative path.
      # @return [String]
      def https_url(url)
        uri = URI.parse(url.to_s).normalize
        return uri.to_s if uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?

        raise ConfigurationError, "presigned transfer refused: URL is not https://host (#{uri.scheme || 'no scheme'})"
      rescue URI::InvalidURIError
        raise ConfigurationError, "presigned transfer refused: invalid URL"
      end

      # Keeps Faraday's default query encoder: re-encoding a signed URL differently could break it.
      def presigned_faraday
        @presigned_faraday ||= Faraday.new(ssl: { cert_store: self.class.default_cert_store }) do |f|
          f.options.timeout = @config.timeout
          f.options.open_timeout = @config.open_timeout
          f.proxy = @config.proxy if @config.proxy
          f.adapter(*Array(@config.adapter))
        end
      end

      def build_faraday
        # The base URL MUST end with "/" so that relative paths (without a leading "/") resolve
        # RELATIVE TO the version prefix (/v2) instead of replacing it — Faraday treats a path with
        # a leading "/" as root-relative and would wipe out "/v2".
        base = @base_url.end_with?("/") ? @base_url : "#{@base_url}/"
        Faraday.new(url: base, ssl: { cert_store: self.class.default_cert_store }) do |f|
          f.options.timeout = @config.timeout
          f.options.open_timeout = @config.open_timeout
          # Array parameters go out as repeated keys (`status=A&status=B`), as the contract defines
          # them; Faraday's default would send `status[]=A`, which the API does not recognize.
          f.options.params_encoder = Faraday::FlatParamsEncoder
          f.proxy = @config.proxy if @config.proxy
          f.adapter(*Array(@config.adapter))
        end
      end

      def run(method, path, bearer:, json:, body:, query:, headers:, raw:, auth:)
        req_headers = build_headers(bearer, json, headers, auth)
        payload = body || (json && JSON.generate(json))

        faraday_response = @faraday.run_request(method, normalize_path(path), payload, req_headers) do |req|
          req.params.update(query) if query
        end

        build_response(faraday_response, raw)
      end

      # Absolute URLs are left as-is; a relative path has its leading "/" stripped so that it
      # resolves against the "…/v2/" base.
      def normalize_path(path)
        path.match?(%r{\Ahttps?://}) ? path : path.sub(%r{\A/+}, "")
      end

      def build_headers(bearer, json, extra, auth)
        headers = {}
        headers.merge!(@config.base_headers) if auth
        headers["Content-Type"] = "application/json" if json
        token = bearer.respond_to?(:call) ? bearer.call : bearer
        headers["Authorization"] = "Bearer #{checked_token(token)}" if auth && token
        headers.merge(stringify(extra))
      end

      # Surrounding whitespace (a token read from a file) is dropped; a control character inside would
      # make net-http echo the whole header into its error.
      def checked_token(token)
        text = token.to_s.strip
        raise ConfigurationError, "the token contains a control character (CR, LF, …)" if text.match?(/[[:cntrl:]]/)

        text
      end

      def build_response(faraday_response, raw)
        raw_body = faraday_response.body.to_s
        check_length!(faraday_response.headers || {}, raw_body)
        parsed = raw ? nil : parse_json(raw_body)
        Response.new(
          status: faraday_response.status,
          headers: faraday_response.headers || {},
          body: parsed,
          raw_body: raw_body
        )
      end

      # Net::HTTP returns a body cut short by a dropped connection without an error.
      def check_length!(headers, raw_body)
        expected = headers["content-length"] || headers["Content-Length"]
        return if expected.nil? || headers["content-encoding"] || headers["Content-Encoding"]
        return unless raw_body.bytesize < Integer(expected, exception: false).to_i

        raise TruncatedBody, "response body cut short: #{raw_body.bytesize} of #{expected} bytes"
      end

      def parse_json(raw_body)
        return nil if raw_body.nil? || raw_body.strip.empty?

        JSON.parse(raw_body)
      rescue JSON::ParserError
        raw_body
      end

      # One debug line and one {NOTIFICATION} per attempt. A presigned URL carries a signature, so it is
      # reported as "presigned"; a KSeF path loses any query string.
      def observe(method, path)
        payload = { method: method.to_s.upcase, path: path.to_s.sub(/\?.*\z/m, ""), status: nil }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = instrument(payload) { yield.tap { |res| payload[:status] = res.status } }
        log_request(payload, payload[:status], started)
        response
      rescue StandardError => e
        log_request(payload, e.class.name, started)
        raise
      end

      def instrument(payload, &)
        return yield unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.instrument(NOTIFICATION, payload, &)
      end

      def log_request(payload, outcome, started)
        logger = @config.logger
        return unless logger

        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        logger.debug { "[ksef] #{payload[:method]} #{payload[:path]} -> #{outcome} (#{ms} ms)" }
      end

      # Up to config.max_retries retries: a 429 (any method — the request was not processed) after its
      # Retry-After, unless the server asks for longer than config.max_retry_after; for idempotent
      # requests also 5xx and network failures, with exponential backoff; for any request a failure that
      # happened before anything was sent (a pool checkout or a connect timeout). TLS failures are not
      # retried, except a peer that dropped a reused keep-alive connection without close_notify.
      def with_retries(idempotent, target)
        attempt = 0
        loop do
          attempt += 1
          begin
            response = yield
          rescue *TLS_ERRORS => e
            raise network_error(e, target) unless idempotent && dropped?(e) && retry_allowed?(attempt)

            pause(backoff(attempt), e.class.name)
            next
          rescue *TRANSPORT_ERRORS => e
            raise network_error(e, target) unless (idempotent || never_sent?(e)) && retry_allowed?(attempt)

            pause(backoff(attempt), e.class.name)
            next
          end
          delay = retry_delay(response, idempotent, attempt) if retry_allowed?(attempt)
          return response unless delay

          pause(delay, "HTTP #{response.status}")
        end
      end

      # OpenSSL 3 reports a peer that closed the connection without close_notify as an SSL error.
      def dropped?(error)
        error.message.match?(/unexpected eof/i)
      end

      # A pool checkout timeout (more threads than `pool_size`) or a connect timeout: the request never
      # left the process.
      def never_sent?(error)
        causes(error).any? do |cause|
          cause.is_a?(Net::OpenTimeout) || (defined?(ConnectionPool::TimeoutError) && cause.is_a?(ConnectionPool::TimeoutError))
        end
      end

      def causes(error)
        chain = []
        while error && chain.size < 10
          chain << error
          error = error.cause
        end
        chain
      end

      def retry_allowed?(attempt)
        attempt <= @config.max_retries
      end

      # @return [Numeric, nil] seconds to wait before retrying the response, nil when it is final
      def retry_delay(response, idempotent, attempt)
        if response.status == 429
          seconds = (ErrorParser.retry_after_seconds(response.headers) || 1).clamp(0..)
          seconds if @config.max_retry_after.nil? || seconds <= @config.max_retry_after
        elsif idempotent && RETRY_STATUSES.include?(response.status)
          backoff(attempt)
        end
      end

      def backoff(attempt)
        RETRY_BASE_DELAY * (2**(attempt - 1))
      end

      def pause(seconds, reason)
        @config.logger&.warn("[ksef] #{reason} — retrying in #{seconds}s")
        sleep(seconds)
      end

      def network_error(error, target)
        timeout = error.is_a?(Faraday::TimeoutError) || error.is_a?(Timeout::Error)
        klass = timeout && !never_sent?(error) ? RequestTimeout : NetworkError
        klass.new("#{target}: #{error.class}: #{error.message}")
      end

      # A 2xx body that is not JSON — an HTML page from a proxy, WAF or maintenance screen — would
      # otherwise reach the resources as a String and read as an empty result. A JSON-typed body (cut
      # short, say) is not quoted: it may carry a token.
      def unexpected_body_error(response, expected = "JSON")
        type = response.header("Content-Type") || "no Content-Type"
        if type.match?(JSON_TYPES)
          return ApiError.new("Unexpected #{type} response of #{response.raw_body.bytesize} bytes that is not " \
                              "valid #{expected}", status: response.status)
        end

        excerpt = ErrorParser.excerpt(response.raw_body)
        ApiError.new("Unexpected non-#{expected} response (#{type}): #{excerpt}",
                     status: response.status, body: excerpt)
      end

      def xml_document?(response)
        return false if response.header("Content-Type").to_s.match?(%r{\Atext/html}i)

        start = response.raw_body.byteslice(0, 512).to_s.b.delete_prefix("\xEF\xBB\xBF".b).lstrip
        start.start_with?("<") && !start.match?(/\A<(?:!doctype\s+html|html[\s>])/i)
      end

      def log_system_warning(response)
        warning = response.header("X-System-Warning")
        return unless warning && !warning.to_s.empty?

        @config.logger&.warn("[ksef] X-System-Warning: #{warning}")
      end

      def raise_on_error(response)
        raise ErrorParser.build_error(
          status: response.status,
          body: response.body || response.raw_body,
          headers: response.headers
        )
      end

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end
    end
  end
end
