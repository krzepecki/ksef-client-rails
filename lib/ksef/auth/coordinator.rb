# frozen_string_literal: true

module Ksef
  module Auth
    # Authentication coordinator: orchestrates the full flow
    # challenge → signature|token → POST → polling GET /auth/{ref} → redeem → (refresh).
    #
    # Polling returns `status.code` inside a 200 body (NOT an HTTP code): 100 in progress,
    # 200 OK, everything else is an error — see {Ksef::AuthenticationFailed}.
    class Coordinator
      # The "operation in progress" code.
      STATUS_IN_PROGRESS = 100
      # The "authenticated" code.
      STATUS_SUCCESS = 200

      # Context key → AuthenticationContextIdentifierType enum value (PascalCase).
      CONTEXT_TYPES = {
        nip: "Nip",
        internal_id: "InternalId",
        nip_vat_ue: "NipVatUe",
        peppol_id: "PeppolId"
      }.freeze

      # Authentication result: the token pair plus the auth session reference number.
      Result = Struct.new(:reference_number, :access_token, :access_token_valid_until,
                          :refresh_token, :refresh_token_valid_until, keyword_init: true) do
        # Tokens never go to error pages, `pp` output or exception reports.
        # @return [String]
        def inspect
          "#<#{self.class.name} reference_number=#{reference_number.inspect} " \
            "access_token=[REDACTED] access_token_valid_until=#{access_token_valid_until.inspect} " \
            "refresh_token=[REDACTED] refresh_token_valid_until=#{refresh_token_valid_until.inspect}>"
        end
        alias_method :to_s, :inspect

        # `pp` and IRB print through #pretty_print, which Struct implements without calling #inspect.
        def pretty_print(printer)
          printer.text(inspect)
        end
      end

      # @param client [Ksef::Client]
      def initialize(client)
        @client = client
      end

      # Authenticates with an XAdES signature (local certificate or an external signer).
      #
      # @param context [Hash] one of {nip:}, {internal_id:}, {nip_vat_ue:}, {peppol_id:}; a NIP is
      #   normalized ({Ksef::Nip.normalize!}) and an invalid one raises Ksef::ConfigurationError
      # @param signer [#sign, #call] {Ksef::Xades::Signer} or a lambda signing the XML
      # @param subject_identifier_type [Symbol] :certificate_subject|:certificate_fingerprint
      # @param allowed_ips [Hash, nil] {addresses:, ranges:, masks:}
      # @param verify_certificate_chain [Boolean]
      # @param poll [Hash] polling options (timeout:, interval:, ...)
      # @return [Result]
      # @raise [Ksef::ConfigurationError] for an invalid context, subject type, allowed_ips or signer — before
      #   any request
      def authenticate(context:, signer:, subject_identifier_type: :certificate_subject,
                       allowed_ips: nil, verify_certificate_chain: false, poll: {})
        signer = Xades::ExternalSigner.wrap(signer) # an unusable signer fails before any request
        request = Xades::AuthTokenRequest.new(context: context, subject_identifier_type: subject_identifier_type,
                                              allowed_ips: allowed_ips)
        request.challenge = @client.auth.challenge["challenge"]
        signed = Xades::ExternalSigner.signed!(signer.sign(request.to_xml))
        init = @client.auth.submit_xades(signed, verify_certificate_chain: verify_certificate_chain)
        finalize(init, poll)
      end

      # Authenticates with an encrypted KSeF token (RSA-OAEP).
      #
      # @param context [Hash] one of {nip:}, {internal_id:}, {nip_vat_ue:}, {peppol_id:}; a NIP is
      #   normalized ({Ksef::Nip.normalize!}) and an invalid one raises Ksef::ConfigurationError
      # @param token [String] KSeF token (secret)
      # @param poll [Hash] polling options
      # @return [Result]
      def authenticate_with_token(context:, token:, poll: {})
        type, value = context_type_and_value(context)
        encryptor = KsefTokenEncryptor.new(crypto: @client.crypto, public_keys: @client.public_keys)
        # A retry after key rotation starts over with a fresh challenge.
        init = @client.public_keys.with_rotation_retry do
          challenge = @client.auth.challenge
          encrypted = encryptor.encrypt(token: token, timestamp_ms: challenge["timestampMs"])
          @client.auth.submit_ksef_token(
            challenge: challenge["challenge"],
            context_type: type,
            context_value: value,
            encrypted_token: encrypted.encrypted_token,
            public_key_id: encrypted.public_key_id
          )
        end
        finalize(init, poll)
      end

      # Refreshes the accessToken using the refresh token.
      # @param refresh_token [String]
      # @return [Hash] { "accessToken" => {token, validUntil} }
      def refresh(refresh_token:)
        @client.auth.refresh(refresh_token: refresh_token)
      end

      private

      def finalize(init, poll_opts)
        reference_number = init["referenceNumber"]
        auth_token = token!(init, "authenticationToken", "the authentication init")
        wait_until_authenticated(reference_number, auth_token, poll_opts)

        tokens = @client.auth.redeem(authentication_token: auth_token)
        Result.new(
          reference_number: reference_number,
          access_token: token!(tokens, "accessToken", "POST /auth/token/redeem"),
          access_token_valid_until: tokens.dig("accessToken", "validUntil"),
          refresh_token: token!(tokens, "refreshToken", "POST /auth/token/redeem"),
          refresh_token_valid_until: tokens.dig("refreshToken", "validUntil")
        )
      end

      def token!(response, key, operation)
        token = response[key].is_a?(Hash) ? response[key]["token"] : nil
        return token unless token.to_s.empty?

        raise ApiError, "#{operation}: KSeF's response lacks #{key}.token"
      end

      def wait_until_authenticated(reference_number, auth_token, poll_opts)
        Polling.run(description: "auth #{reference_number}", logger: @client.config.logger, **poll_opts) do
          response = @client.auth.status(reference_number, authentication_token: auth_token)
          interpret_status(response)
        end
      end

      def interpret_status(response)
        status = response["status"] || {}
        case status["code"]
        when STATUS_IN_PROGRESS
          Polling.pending
        when STATUS_SUCCESS
          response
        else
          raise AuthenticationFailed.new(
            status["description"] || "Authentication failed",
            code: status["code"],
            messages: status["details"]
          )
        end
      end

      def context_type_and_value(context)
        unless context.is_a?(Hash)
          raise ConfigurationError, "context must be a Hash with exactly one of: #{CONTEXT_TYPES.keys.join(', ')}"
        end

        pairs = context.transform_keys(&:to_sym)
        key, value = pairs.first
        unless pairs.size == 1 && CONTEXT_TYPES.key?(key)
          raise ConfigurationError, "context must contain exactly one of: #{CONTEXT_TYPES.keys.join(', ')}"
        end

        [CONTEXT_TYPES.fetch(key), key == :nip ? Nip.normalize!(value, name: "context nip") : value.to_s]
      end
    end
  end
end
