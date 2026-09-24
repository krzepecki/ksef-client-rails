# frozen_string_literal: true

module Ksef
  module Resources
    # Base class for domain resources: wraps one API area and delegates to
    # {Ksef::Http::Connection} with the client's access token, overridable per call. Endpoint
    # paths live as constants in the subclasses, so contract changes are easy to diff.
    class Base
      # @param client [Ksef::Client]
      def initialize(client)
        @client = client
      end

      private

      # @return [Ksef::Http::Connection]
      def connection
        @client.connection
      end

      # @return [Ksef::Configuration]
      def config
        @client.config
      end

      # @return [String, nil] the client's default access token
      def access_token
        @client.access_token
      end

      # The client's token, read when each request attempt is sent (a callable token can change between
      # a 429 and its retry).
      # @return [Proc]
      def default_bearer
        -> { @client.access_token }
      end

      # Verb shortcuts: parsed body, access token by default, overridable per call via `bearer:`. With
      # `returns:` (the keys the caller needs, possibly none) the 2xx body must be a JSON object holding them.
      def get(path, bearer: default_bearer, returns: nil, **)
        checked(connection.get(path, bearer: bearer, **).body, "GET", path, returns)
      end

      def post(path, bearer: default_bearer, returns: nil, **)
        checked(connection.post(path, bearer: bearer, **).body, "POST", path, returns)
      end

      def delete(path, bearer: default_bearer, returns: nil, **)
        checked(connection.delete(path, bearer: bearer, **).body, "DELETE", path, returns)
      end

      def put(path, bearer: default_bearer, returns: nil, **)
        checked(connection.put(path, bearer: bearer, **).body, "PUT", path, returns)
      end

      def checked(body, verb, path, returns)
        returns.nil? ? body : object!(body, "#{verb} #{path}", required: returns)
      end

      # A call whose 2xx response is a JSON object: an empty body, `null` or an array raises instead of
      # reaching the caller as nil, and so does an object without one of the +required+ keys.
      # @param body [Object] the parsed response body
      # @param operation [String] e.g. "POST /tokens", for the error message
      # @param required [Array<String>] keys the caller needs
      # @return [Hash]
      # @raise [Ksef::ApiError]
      def object!(body, operation, required: [])
        processed = operation.start_with?("GET ") ? "" : " — the request may have been processed"
        unless body.is_a?(Hash)
          raise ApiError, "#{operation}: KSeF returned #{body.nil? ? 'an empty body' : "a JSON #{body.class}"} " \
                          "instead of an object#{processed}"
        end
        missing = required.reject { |key| body.key?(key) && !body[key].nil? }
        return body if missing.empty?

        raise ApiError, "#{operation}: KSeF's response lacks #{missing.join(', ')}#{processed}"
      end

      # GET returning an XML document (invoice, UPO) unparsed. Faraday hands back BINARY bytes; KSeF
      # serves these documents as UTF-8, so the string is tagged UTF-8 — otherwise combining it with
      # any other text raises Encoding::CompatibilityError on the first Polish character. A 2xx that is
      # no XML document raises, and so do bytes that do not match the `x-ms-meta-hash` KSeF sends.
      def get_raw(path, bearer: default_bearer, **)
        response = connection.get(path, bearer: bearer, raw: :xml, **)
        verify_hash!(response)
        response.raw_body.dup.force_encoding(Encoding::UTF_8)
      end

      def verify_hash!(response)
        expected = response.header("x-ms-meta-hash").to_s.strip
        return if expected.empty?

        require "digest"
        require "base64"
        return if Base64.strict_encode64(Digest::SHA256.digest(response.raw_body)) == expected

        raise ApiError.new("the downloaded document does not match its x-ms-meta-hash (SHA-256)",
                           status: response.status)
      end

      # Builds a path from segments, escaping the variable values.
      # @return [String]
      # @raise [Ksef::ConfigurationError] for a blank segment, "." or ".." — URI resolution would drop
      #   or climb it, and the request would reach another endpoint
      def path(*segments)
        "/#{segments.map { |s| encode_segment(s) }.join('/')}"
      end

      def encode_segment(segment)
        text = segment.to_s
        if text.strip.empty? || text.match?(/\A\.{1,2}\z/)
          raise ConfigurationError, "Invalid path segment: #{segment.inspect}"
        end

        require "erb"
        ERB::Util.url_encode(text)
      end
    end
  end
end
