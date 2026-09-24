# frozen_string_literal: true

require "base64"
require "json"
require "time"

module Ksef
  # Optional, thread-safe token manager: holds the access/refresh pair and refreshes the accessToken
  # before it expires — at `validUntil`, or at the token's own JWT `exp` claim when that is not given.
  # A refreshed token that already expires within the skew is used until it expires, so a skew longer
  # than the token's lifetime does not turn into a refresh per request.
  class TokenManager
    # Default margin (s) before expiry at which the token is refreshed.
    DEFAULT_SKEW = 60

    # @param client [Ksef::Client]
    # @param access_token [String]
    # @param refresh_token [String]
    # @param access_token_valid_until [String, Time, DateTime, nil] accessToken expiry time; nil reads the
    #   `exp` claim of the access token (a JWT)
    # @param skew [Integer] safety margin before expiry (s)
    # @param on_refresh [#call, nil] called with the new access token and its expiry (Time, nil when
    #   unknown) after every refresh — e.g. to persist them. It runs outside the manager's lock, so it may
    #   use the manager or its client; an exception it raises propagates, and the callback runs again on
    #   the next {#access_token}
    def initialize(client, access_token:, refresh_token:, access_token_valid_until: nil, skew: DEFAULT_SKEW,
                   on_refresh: nil)
      @client = client
      @access_token = access_token
      @refresh_token = refresh_token
      @valid_until = parse_time(access_token_valid_until) || jwt_expiry(access_token)
      @skew = skew
      @skew_active = true
      @on_refresh = on_refresh
      @mutex = Mutex.new
    end

    # Returns a valid accessToken, refreshing it when needed (thread-safe).
    # @return [String]
    def access_token
      token, pending = @mutex.synchronize do
        refresh_locked! if expired?
        [@access_token, @pending_callback]
      end
      notify(pending) if pending
      token
    end

    # @return [String] the current refreshToken
    attr_reader :refresh_token

    # @return [Time, nil] expiry of the current accessToken, nil when unknown
    def access_token_valid_until
      @mutex.synchronize { @valid_until }
    end

    # Forces an accessToken refresh.
    # @return [String] the new accessToken
    def force_refresh!
      token, pending = @mutex.synchronize { [refresh_locked!, @pending_callback] }
      notify(pending) if pending
      token
    end

    # Keeps both tokens out of error pages, `pp` output and exception reports.
    # @return [String]
    def inspect
      "#<#{self.class.name} valid_until=#{@valid_until.inspect} access_token=[REDACTED] refresh_token=[REDACTED]>"
    end

    private

    def expired?
      return true if @access_token.nil?
      return false if @valid_until.nil?

      Time.now >= (@skew_active ? @valid_until - @skew : @valid_until)
    end

    # A response without a token keeps the current one.
    def refresh_locked!
      response = @client.auth.refresh(refresh_token: @refresh_token)
      token = response["accessToken"].is_a?(Hash) ? response["accessToken"]["token"] : nil
      raise ApiError, "POST /auth/token/refresh: KSeF's response lacks accessToken.token" if token.to_s.empty?

      @access_token = token
      @valid_until = parse_time(response.dig("accessToken", "validUntil")) || jwt_expiry(@access_token)
      @skew_active = @valid_until.nil? || @valid_until - Time.now > @skew
      @pending_callback = [@access_token, @valid_until] if @on_refresh
      @access_token
    end

    # Claims the pending callback (one thread runs it), and puts it back when it fails.
    def notify(pending)
      @mutex.synchronize do
        return unless @pending_callback.equal?(pending)

        @pending_callback = nil
      end
      begin
        @on_refresh.call(*pending)
      rescue StandardError
        @mutex.synchronize { @pending_callback ||= pending }
        raise
      end
    end

    def parse_time(value)
      return nil if value.nil?
      return value if value.is_a?(Time)
      return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # The `exp` claim (seconds since the epoch) of a JWT, read without verifying the signature — it
    # only decides when to refresh.
    def jwt_expiry(token)
      payload = token.to_s.split(".")[1]
      return nil if payload.nil? || payload.empty?

      exp = JSON.parse(Base64.urlsafe_decode64(payload))["exp"]
      exp.is_a?(Numeric) ? Time.at(exp) : nil
    rescue ArgumentError, TypeError, JSON::ParserError
      nil
    end
  end
end
