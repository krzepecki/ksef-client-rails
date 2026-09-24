# frozen_string_literal: true

module Ksef
  module Resources
    # Collective identifiers — one number for a set of invoices of one seller, e.g. a single payment.
    # Lists use continuation-token pagination. Every endpoint requires an accessToken with
    # InvoiceRead, InvoiceWrite or CollectiveIdentifierManage.
    class CollectiveIdentifiers < Base
      COLLECTIVE_IDENTIFIERS = "/collective-identifiers"
      QUERY = "/collective-identifiers/query"
      INVOICES = "/collective-identifiers/invoices"

      # POST /collective-identifiers — generates a collective identifier for invoices of one seller.
      # @param invoices [Array<Hash>] [{ "ksefNumber", "payment" => { "amount", "currency" }?, "description"? }]
      # @return [Hash] { "collectiveIdentifierNumber" }
      def generate(invoices:)
        post(COLLECTIVE_IDENTIFIERS, json: { "invoices" => invoices }, returns: %w[collectiveIdentifierNumber])
      end

      # POST /collective-identifiers/query — identifiers generated in (or naming) the context.
      # @param filters [Hash] CollectiveIdentifiersQueryRequest: "dateCreatedFrom" and "dateCreatedTo" are
      #   required (at most 100 days apart); "collectiveIdentifierNumber", "invoiceCountFrom"/"To",
      #   "createdInCurrentContext" are optional
      # @param page_size [Integer] 10..200
      # @return [Enumerator::Lazy<Hash>] identifier entries
      def query(filters:, page_size: 50)
        paginate(QUERY, filters, "collectiveIdentifiers", page_size)
      end

      # POST /collective-identifiers/invoices — the invoices of up to 10 collective identifiers.
      # @param collective_identifier_numbers [Array<String>]
      # @param page_size [Integer] 10..500
      # @return [Enumerator::Lazy<Hash>] { "ksefNumber", "collectiveIdentifierNumber", "payment"?, ... }
      def invoices(collective_identifier_numbers:, page_size: 100)
        paginate(INVOICES, { "collectiveIdentifierNumbers" => Array(collective_identifier_numbers) }, "invoices",
                 page_size)
      end

      # GET /collective-identifiers/ksef/{ksefNumber} — the collective identifiers an invoice belongs to.
      # @param ksef_number [String]
      # @param page_size [Integer] 10..200
      # @return [Enumerator::Lazy<Hash>] identifier entries
      def by_ksef_number(ksef_number, page_size: 50)
        endpoint = path("collective-identifiers", "ksef", ksef_number)
        Http::Pagination.by_continuation(page_size: page_size) do |token, size|
          page(get(endpoint, query: { "pageSize" => size }, headers: continuation(token), returns: []),
               "collectiveIdentifiers")
        end
      end

      private

      def paginate(endpoint, body, items_key, page_size)
        Http::Pagination.by_continuation(page_size: page_size) do |token, size|
          page(post(endpoint, json: body, query: { "pageSize" => size }, headers: continuation(token), returns: []),
               items_key)
        end
      end

      def continuation(token)
        token ? { "x-continuation-token" => token } : {}
      end

      def page(body, items_key)
        Http::Pagination::ContinuationPage.new(items: body[items_key] || [],
                                               continuation_token: body["continuationToken"])
      end
    end
  end
end
