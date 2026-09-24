# frozen_string_literal: true

module Ksef
  # KSeF client facade: configuration, HTTP connection and an optional access
  # token, delegating to 14 domain resources and the cryptography services.
  #
  # `access_token` is per-client state, never global (a callable is read on every request); auth
  # endpoints take their own tokens explicitly through {Ksef::Auth::Coordinator}. The configuration is
  # copied when the client is built, so a later {Ksef.configure} cannot split its environment.
  class Client
    # @return [Ksef::Configuration] this client's copy of the configuration
    attr_reader :config
    # @return [Ksef::Http::Connection]
    attr_reader :connection
    # @return [Ksef::Crypto::PublicKeys] cache of the Ministry of Finance public-key certificates
    attr_reader :public_keys
    # @return [Ksef::Crypto::CryptographyService]
    attr_reader :crypto
    # Replaces the default token (a String or a callable). On a client shared between threads use
    # {#with_access_token} instead — this mutates every caller's client.
    attr_writer :access_token

    # @param access_token [String, #call, nil] the accessToken, or a callable returning the current one
    #   (e.g. `-> { manager.access_token }` with a {Ksef::TokenManager})
    # @param config [Ksef::Configuration, nil] defaults to the global configuration {Ksef.config}; copied
    # @param connection [Ksef::Http::Connection, nil] injectable (for tests)
    # @param public_keys [Ksef::Crypto::PublicKeys, nil] a key cache to share (see {#with_access_token})
    def initialize(access_token: nil, config: nil, connection: nil, public_keys: nil)
      @config = (config || Ksef.config).with
      @access_token = access_token
      @connection = connection || Http::Connection.new(config: @config)
      @public_keys = public_keys || Crypto::PublicKeys.new(connection: @connection, logger: @config.logger)
      @crypto = Crypto::CryptographyService.new(public_keys: @public_keys)
    end

    # @return [String, nil] the access token the resources send by default
    def access_token
      @access_token.respond_to?(:call) ? @access_token.call : @access_token
    end

    # A copy of the client with a different access token, sharing the connection and the key cache —
    # the way to serve many contexts from one client (the original is not mutated).
    # @param token [String, #call]
    # @return [Client]
    def with_access_token(token)
      self.class.new(access_token: token, config: @config, connection: @connection, public_keys: @public_keys)
    end

    # Closes the keep-alive connections (shared with the clients from {#with_access_token}); a later
    # request opens new ones.
    # @return [void]
    def close
      @connection.close
    end

    # Keeps the access token out of error pages, `pp` output and exception reports.
    # @return [String]
    def inspect
      "#<#{self.class.name} environment=#{@config.environment.inspect} " \
        "access_token=#{@access_token ? '[REDACTED]' : 'nil'}>"
    end

    # --- domain resources (1:1 with endpoints) ---

    # @return [Ksef::Resources::Auth] /auth/*
    def auth
      @auth ||= Resources::Auth.new(self)
    end

    # @return [Ksef::Resources::Sessions] session reads/status: GET /sessions*
    def sessions
      @sessions ||= Resources::Sessions.new(self)
    end

    # @return [Ksef::Resources::OnlineSessions] POST /sessions/online*
    def online
      @online ||= Resources::OnlineSessions.new(self)
    end

    # @return [Ksef::Resources::BatchSessions] POST /sessions/batch*
    def batch
      @batch ||= Resources::BatchSessions.new(self)
    end

    # @return [Ksef::Resources::Invoices] invoice downloads + metadata queries
    def invoices
      @invoices ||= Resources::Invoices.new(self)
    end

    # @return [Ksef::Resources::Exports] invoice package exports
    def exports
      @exports ||= Resources::Exports.new(self)
    end

    # @return [Ksef::Resources::CollectiveIdentifiers] /collective-identifiers*
    def collective_identifiers
      @collective_identifiers ||= Resources::CollectiveIdentifiers.new(self)
    end

    # @return [Ksef::Resources::Certificates] /certificates/*
    def certificates
      @certificates ||= Resources::Certificates.new(self)
    end

    # @return [Ksef::Resources::Tokens] KSeF tokens: /tokens*
    def tokens
      @tokens ||= Resources::Tokens.new(self)
    end

    # @return [Ksef::Resources::Permissions] /permissions/*
    def permissions
      @permissions ||= Resources::Permissions.new(self)
    end

    # @return [Ksef::Resources::Limits] /limits/*, /rate-limits
    def limits
      @limits ||= Resources::Limits.new(self)
    end

    # @return [Ksef::Resources::Security] /security/public-key-certificates
    def security
      @security ||= Resources::Security.new(self)
    end

    # @return [Ksef::Resources::Peppol] /peppol/query
    def peppol
      @peppol ||= Resources::Peppol.new(self)
    end

    # @return [Ksef::Resources::TestData] /testdata/* (TEST only)
    def test_data
      @test_data ||= Resources::TestData.new(self)
    end
  end
end
