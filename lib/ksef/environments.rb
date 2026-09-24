# frozen_string_literal: true

module Ksef
  # The public KSeF environments, each with its API and QR host.
  #
  # The path prefix is `/v2`, as in both SDKs — the `/api/v2` seen in the docs is an
  # OpenAPI generator artifact, not a real path.
  module Environments
    # A single environment: API and QR base URLs plus metadata.
    Environment = Struct.new(:key, :api_base_url, :qr_base_url, :api_path_prefix, :description, keyword_init: true) do
      # @return [String] full base URL for API requests (including the version prefix), no trailing "/"
      def request_base_url
        "#{api_base_url}#{api_path_prefix}"
      end
    end

    # Test (Release Candidate). Allows self-signed certificates for authentication.
    # Data is NOT isolated between integrators — use random tax identification numbers.
    TEST = Environment.new(
      key: :test,
      api_base_url: "https://api-test.ksef.mf.gov.pl",
      qr_base_url: "https://qr-test.ksef.mf.gov.pl",
      api_path_prefix: "/v2",
      description: "Test environment (RC) — self-signed allowed, shared data"
    ).freeze

    # Pre-production (Demo) — configuration close to production.
    DEMO = Environment.new(
      key: :demo,
      api_base_url: "https://api-demo.ksef.mf.gov.pl",
      qr_base_url: "https://qr-demo.ksef.mf.gov.pl",
      api_path_prefix: "/v2",
      description: "Pre-production environment (Demo)"
    ).freeze

    # Production — invoices with full legal effect.
    PROD = Environment.new(
      key: :prod,
      api_base_url: "https://api.ksef.mf.gov.pl",
      qr_base_url: "https://qr.ksef.mf.gov.pl",
      api_path_prefix: "/v2",
      description: "Production environment"
    ).freeze

    ALL = { test: TEST, demo: DEMO, prod: PROD }.freeze

    # Returns an environment by key (:test/:demo/:prod), or passes through a ready object.
    #
    # @param key_or_env [Symbol, String, Environment]
    # @return [Environment]
    # @raise [Ksef::ConfigurationError] when the key is unknown
    def self.fetch(key_or_env)
      return key_or_env if key_or_env.is_a?(Environment)

      key = key_or_env.to_s.downcase.to_sym
      ALL.fetch(key) do
        raise ConfigurationError, "Unknown KSeF environment: #{key_or_env.inspect} (allowed: #{ALL.keys.join(', ')})"
      end
    end
  end
end
