# frozen_string_literal: true

module Ksef
  module Resources
    # KSeF token resource — /tokens/* endpoints.
    #
    # Generating authentication tokens, listing them (continuation pagination), checking status
    # and revoking. Every endpoint requires an accessToken.
    class Tokens < Base
      TOKENS = "/tokens"

      # POST /tokens — generates a new KSeF token with the given permissions. The token is returned only
      # here, and starts `Pending`: it authenticates once {#status} reports `Active`.
      # @param permissions [Array<String>] permissions (e.g. "InvoiceRead", "InvoiceWrite")
      # @param description [String] token description
      # @return [Hash] { "referenceNumber", "token" }
      def generate(permissions:, description:)
        post(TOKENS, json: { "permissions" => permissions, "description" => description },
                     returns: %w[referenceNumber token])
      end

      # GET /tokens — token list with filtering (continuation pagination).
      # @param status [Array<String>, String, nil] statuses to filter by (e.g. "Active"); none when empty
      # @param description [String, nil] filter by description
      # @param author_identifier [String, nil] author identifier
      # @param author_identifier_type [String, nil] identifier type ("Nip" / "Pesel" / "Fingerprint")
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>] token entries
      def list(status: nil, description: nil, author_identifier: nil, author_identifier_type: nil, page_size: 20)
        Http::Pagination.by_continuation(page_size: page_size) do |token, size|
          query = {
            "status" => Array(status).empty? ? nil : status,
            "description" => description,
            "authorIdentifier" => author_identifier,
            "authorIdentifierType" => author_identifier_type,
            "pageSize" => size
          }.compact
          headers = token ? { "x-continuation-token" => token } : {}
          body = get(TOKENS, query: query, headers: headers, returns: [])
          Http::Pagination::ContinuationPage.new(
            items: body["tokens"] || [],
            continuation_token: body["continuationToken"]
          )
        end
      end

      # GET /tokens/{referenceNumber} — status of a single token.
      # @param reference_number [String]
      # @return [Hash] TokenStatusResponse (including "status", "requestedPermissions")
      def status(reference_number)
        get(path("tokens", reference_number), returns: %w[status])
      end

      # DELETE /tokens/{referenceNumber} — revokes a token.
      # @param reference_number [String]
      # @return [nil]
      def revoke(reference_number)
        delete(path("tokens", reference_number))
      end
    end
  end
end
