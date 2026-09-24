# frozen_string_literal: true

module Ksef
  module Resources
    # Authentication resource — /auth/* endpoints. Each endpoint names the token it
    # expects in its argument list, so anonymous / authenticationToken / refreshToken / accessToken
    # calls cannot be confused.
    class Auth < Base
      CHALLENGE = "/auth/challenge"
      XADES_SIGNATURE = "/auth/xades-signature"
      KSEF_TOKEN = "/auth/ksef-token"
      TOKEN_REDEEM = "/auth/token/redeem"
      TOKEN_REFRESH = "/auth/token/refresh"
      SESSIONS = "/auth/sessions"
      SESSIONS_CURRENT = "/auth/sessions/current"

      # POST /auth/challenge — fetches the challenge and timestamp (ms). Anonymous.
      # @return [Hash] { "challenge", "timestamp", "timestampMs", "clientIp" }
      def challenge
        post(CHALLENGE, bearer: nil, json: {}, returns: %w[challenge timestampMs])
      end

      # POST /auth/xades-signature — submits the signed XAdES AuthTokenRequest. Anonymous.
      # @param signed_xml [String] signed document (application/xml)
      # @param verify_certificate_chain [Boolean] whether to verify the certificate chain
      # @return [Hash] { "referenceNumber", "authenticationToken" => { "token", "validUntil" } }
      def submit_xades(signed_xml, verify_certificate_chain: false)
        post(
          XADES_SIGNATURE,
          bearer: nil,
          body: signed_xml,
          headers: { "Content-Type" => "application/xml" },
          query: { "verifyCertificateChain" => verify_certificate_chain },
          returns: %w[referenceNumber authenticationToken]
        )
      end

      # POST /auth/ksef-token — authentication with an encrypted KSeF token. Anonymous.
      # @param challenge [String]
      # @param context_type [String] context type: "Nip", "InternalId", "NipVatUe" or "PeppolId"
      # @param context_value [String]
      # @param encrypted_token [String] Base64 RSA-OAEP("token|timestampMs")
      # @param public_key_id [String, nil]
      # @return [Hash] init response (referenceNumber + authenticationToken)
      def submit_ksef_token(challenge:, context_type:, context_value:, encrypted_token:, public_key_id: nil)
        body = {
          "challenge" => challenge,
          "contextIdentifier" => { "type" => context_type, "value" => context_value },
          "encryptedToken" => encrypted_token
        }
        body["publicKeyId"] = public_key_id if public_key_id
        post(KSEF_TOKEN, bearer: nil, json: body, returns: %w[referenceNumber authenticationToken])
      end

      # GET /auth/{referenceNumber} — status of the authentication operation. Bearer: authenticationToken.
      # @param reference_number [String]
      # @param authentication_token [String]
      # @return [Hash] AuthenticationOperationStatusResponse (including "status" => {code, description, details})
      def status(reference_number, authentication_token:)
        get(path("auth", reference_number), bearer: authentication_token, returns: %w[status])
      end

      # POST /auth/token/redeem — issues the accessToken and refreshToken. Bearer: authenticationToken.
      # @param authentication_token [String]
      # @return [Hash] { "accessToken" => {token, validUntil}, "refreshToken" => {token, validUntil} }
      def redeem(authentication_token:)
        post(TOKEN_REDEEM, bearer: authentication_token, json: {}, returns: %w[accessToken refreshToken])
      end

      # POST /auth/token/refresh — refreshes the accessToken. Bearer: refreshToken.
      # @param refresh_token [String]
      # @return [Hash] { "accessToken" => {token, validUntil} }
      # @raise [Ksef::ReauthenticationRequired] when the refresh token can no longer be used (a 401, or a
      #   400 with 21301/21304)
      def refresh(refresh_token:)
        post(TOKEN_REFRESH, bearer: refresh_token, json: {}, returns: %w[accessToken])
      rescue Unauthorized => e
        raise ReauthenticationRequired.new("the refresh token can no longer be used",
                                           status: e.status, codes: e.codes, trace_id: e.trace_id,
                                           details: e.details, body: e.body)
      end

      # GET /auth/sessions — list of active authentication sessions (continuation pagination).
      # @param access_token [String, nil] defaults to the client token, read for every page
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>] session entries
      def sessions(access_token: nil, page_size: 20)
        Http::Pagination.by_continuation(page_size: page_size) do |token, size|
          query = { "pageSize" => size }
          headers = token ? { "x-continuation-token" => token } : {}
          body = get(SESSIONS, bearer: access_token || default_bearer, query: query, headers: headers, returns: [])
          Http::Pagination::ContinuationPage.new(
            items: body["items"] || body["authenticationTokens"] || [],
            continuation_token: body["continuationToken"]
          )
        end
      end

      # DELETE /auth/sessions/current — revokes the current auth session (refresh token).
      # Accepts a refreshToken OR an accessToken; already-issued accessTokens work until expiry.
      # @param token [String]
      # @return [nil]
      def revoke_current_session(token:)
        delete(SESSIONS_CURRENT, bearer: token)
      end

      # DELETE /auth/sessions/{referenceNumber} — revokes the given auth session. Bearer: accessToken.
      # @param reference_number [String]
      # @param access_token [String, nil] defaults to the client token
      # @return [nil]
      def revoke_session(reference_number, access_token: nil)
        delete(path("auth", "sessions", reference_number), bearer: access_token || default_bearer)
      end
    end
  end
end
