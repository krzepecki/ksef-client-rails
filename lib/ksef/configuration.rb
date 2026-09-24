# frozen_string_literal: true

require "logger"
require "uri"

module Ksef
  # Gem configuration: global via {Ksef.configure}, or per client — see {Ksef::Client}.
  class Configuration
    # Default timeouts (seconds).
    DEFAULT_TIMEOUT = 60
    DEFAULT_OPEN_TIMEOUT = 15
    # Faraday adapter: keep-alive, so back-to-back calls reuse one TLS connection per host.
    DEFAULT_ADAPTER = :net_http_persistent
    # Longest server-requested `Retry-After` (seconds) the client sleeps through on a 429; anything
    # longer surfaces as {Ksef::RateLimited} so a web worker or job is never parked for hours.
    DEFAULT_MAX_RETRY_AFTER = 60
    # Options settable through {#apply} (and Rails `config.ksef.*`).
    OPTIONS = %i[
      environment timeout open_timeout proxy logger api_base_url_override qr_base_url_override
      default_headers prefer_problem_details ksef_features max_retries max_retry_after adapter user_agent
    ].freeze

    # @return [Symbol] environment key (:test/:demo/:prod)
    attr_reader :environment

    # @return [Numeric] response timeout (s)
    attr_reader :timeout
    # @return [Numeric] connection open timeout (s)
    attr_reader :open_timeout
    # @return [String, nil] proxy URL (e.g. "http://proxy.local:3128"); defaults to ENV["KSEF_PROXY"]
    attr_accessor :proxy
    # @return [Logger, nil] logger; when nil, logging is disabled
    attr_accessor :logger
    # @return [String, nil] override for the API base URL (for tests/mocks)
    attr_accessor :api_base_url_override
    # @return [String, nil] override for the QR base URL
    attr_accessor :qr_base_url_override
    # @return [Hash{String=>String}] extra headers appended to every request
    attr_accessor :default_headers
    # @return [Boolean] whether to send the X-Error-Format: problem-details header (like C#)
    attr_accessor :prefer_problem_details
    # @return [Array<String>] feature flags sent in the X-KSeF-Feature header (e.g.
    #   "subject-identifier-validation"; "upo-v4-3", "include-metadata" and the strict XAdES rules
    #   are KSeF's default behaviour and need no flag)
    attr_accessor :ksef_features
    # @return [Integer] retries per request: a 429 for any call, 500/502/503/504 and network failures for
    #   idempotent ones (GET, presigned transfers)
    attr_reader :max_retries
    # @return [Numeric, nil] upper bound (s) for a `Retry-After` the client honours on a 429; nil — no bound
    attr_reader :max_retry_after
    # @return [Symbol, Array] Faraday adapter (plus options), {DEFAULT_ADAPTER} by default — e.g.
    #   [:net_http_persistent, { pool_size: 5 }], or :net_http to turn keep-alive off
    attr_accessor :adapter
    # @return [String] gem User-Agent
    attr_accessor :user_agent

    # @param environment [Symbol, String, Environments::Environment] defaults to :test
    def initialize(environment: :test)
      self.environment = environment
      @timeout = DEFAULT_TIMEOUT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @proxy = ENV.fetch("KSEF_PROXY", nil)
      @logger = nil
      @default_headers = {}
      @prefer_problem_details = true
      @ksef_features = []
      @max_retries = 2
      @max_retry_after = DEFAULT_MAX_RETRY_AFTER
      @adapter = DEFAULT_ADAPTER
      @user_agent = "ksef-ruby/#{Ksef::VERSION}"
    end

    # @param value [Numeric] seconds, > 0
    # @raise [Ksef::ConfigurationError]
    def timeout=(value)
      @timeout = positive!(:timeout, value)
    end

    # @param value [Numeric] seconds, > 0
    # @raise [Ksef::ConfigurationError]
    def open_timeout=(value)
      @open_timeout = positive!(:open_timeout, value)
    end

    # @param value [Integer] >= 0
    # @raise [Ksef::ConfigurationError]
    def max_retries=(value)
      raise ConfigurationError, "max_retries must be an Integer >= 0, got #{value.inspect}" unless
        value.is_a?(Integer) && value >= 0

      @max_retries = value
    end

    # @param value [Numeric, nil] seconds, >= 0
    # @raise [Ksef::ConfigurationError]
    def max_retry_after=(value)
      raise ConfigurationError, "max_retry_after must be nil or a number >= 0, got #{value.inspect}" unless
        value.nil? || (value.is_a?(Numeric) && value >= 0)

      @max_retry_after = value
    end

    # Sets the environment by key or by {Environments::Environment} object.
    # @param value [Symbol, String, Environments::Environment]
    def environment=(value)
      @env = Environments.fetch(value)
      @environment = @env.key
    end

    # @return [Environments::Environment] the resolved environment object
    attr_reader :env

    # @return [String] base URL for API requests (with the /v2 prefix), honouring the override
    def api_url
      base = api_base_url_override || env.api_base_url
      "#{base.chomp('/')}#{env.api_path_prefix}"
    end

    # @return [String] base QR URL (without a version prefix)
    def qr_url
      (qr_base_url_override || env.qr_base_url).chomp("/")
    end

    # Assigns every option present in +options+; an unknown key raises, so a typo does not pass silently.
    # @param options [Hash{Symbol, String => Object}] e.g. Rails `config.ksef`
    # @return [self]
    # @raise [Ksef::ConfigurationError] for an unknown option
    def apply(options)
      options.each do |name, value|
        key = name.to_sym
        unless OPTIONS.include?(key)
          raise ConfigurationError, "Unknown KSeF option: #{name} (allowed: #{OPTIONS.join(', ')})"
        end

        public_send("#{key}=", value)
      end
      self
    end

    # A copy with some options changed — e.g. a client for another environment that keeps what the
    # Railtie or an initializer set. Headers and feature flags are copied; the logger is shared.
    # @param options [Hash{Symbol, String => Object}] any {OPTIONS} key
    # @return [Configuration]
    # @raise [Ksef::ConfigurationError] for an unknown option
    def with(**options)
      copy = dup
      copy.default_headers = default_headers.dup
      copy.ksef_features = ksef_features.dup
      copy.apply(options)
    end

    # Sends `X-KSeF-Feature: enforce-xades-compliance`. Optional: KSeF applies the strict XAdES
    # validation on every environment with or without it.
    # @return [self]
    def enforce_xades_compliance!
      @ksef_features |= ["enforce-xades-compliance"]
      self
    end

    # Keeps a proxy password out of logs, `pp` output and exception reports.
    # @return [String]
    def inspect
      fields = instance_variables.map do |name|
        value = instance_variable_get(name)
        value = redacted_proxy(value) if name == :@proxy && value
        "#{name.to_s.delete_prefix('@')}=#{value.inspect}"
      end
      "#<#{self.class.name} #{fields.join(', ')}>"
    end

    # Builds the invariant headers appended to every request (Authorization aside).
    # @return [Hash{String=>String}]
    def base_headers
      headers = {
        "User-Agent" => user_agent,
        "Accept" => "application/json"
      }
      headers["X-Error-Format"] = "problem-details" if prefer_problem_details
      headers["X-KSeF-Feature"] = ksef_features.join(", ") unless ksef_features.empty?
      headers.merge(default_headers)
    end

    private

    def positive!(name, value)
      return value if value.is_a?(Numeric) && value.positive?

      raise ConfigurationError, "#{name} must be a number of seconds > 0, got #{value.inspect}"
    end

    # Every form Faraday accepts — "scheme://user:pass@host", "user:pass@host", a Hash or ProxyOptions —
    # shown as scheme://host:port only.
    def redacted_proxy(value)
      uri = value.respond_to?(:to_hash) || value.respond_to?(:uri) ? proxy_uri(value) : value.to_s
      uri = URI.parse(uri.to_s.include?("://") ? uri.to_s : "http://#{uri}")
      credentials = uri.userinfo || (value.respond_to?(:to_hash) && (value.to_hash[:user] || value.to_hash[:password]))
      "#{uri.scheme}://#{'[REDACTED]@' if credentials}#{uri.host}#{":#{uri.port}" if uri.port}"
    rescue URI::InvalidURIError
      "[REDACTED]"
    end

    def proxy_uri(value)
      value.respond_to?(:uri) ? value.uri : (value.to_hash[:uri] || value.to_hash["uri"])
    end
  end
end
