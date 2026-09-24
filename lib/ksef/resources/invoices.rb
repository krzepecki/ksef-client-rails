# frozen_string_literal: true

module Ksef
  module Resources
    # Invoice download resource — GET by KSeF number + metadata query. The download is checked against
    # the invoice's SHA-256 that KSeF sends in `x-ms-meta-hash`.
    class Invoices < Base
      QUERY_METADATA = "/invoices/query/metadata"
      # Result sort order (SortOrder in the contract); the field is picked from `dateRange.dateType`.
      SORT_ORDERS = %w[Asc Desc].freeze

      # GET /invoices/ksef/{ksefNumber} — downloads an invoice by KSeF number (XML).
      # @param ksef_number [String]
      # @return [String] invoice (application/xml)
      # @raise [Ksef::ApiError] for a 2xx that is no XML document or does not match `x-ms-meta-hash`
      def get_by_ksef_number(ksef_number)
        get_raw(path("invoices", "ksef", ksef_number))
      end

      # POST /invoices/query/metadata — invoice metadata query (offset pagination).
      #
      # Date range limited to 100 days (UTC). A filter set yields at most 10,000 records: iterating past
      # them raises {Ksef::ResultTruncated} — continue with {#query_metadata_page} and a narrower range.
      # The endpoint allows 20 requests an hour, hence the largest page by default.
      #
      # @param filters [Hash] query filters (InvoiceQueryFilters)
      # @param page_size [Integer] 10..250
      # @param sort_order [String, nil] "Asc" (API default) or "Desc"
      # @return [Enumerator::Lazy<Hash>] individual metadata entries
      def query_metadata(filters:, page_size: 250, sort_order: nil)
        validate_sort_order(sort_order) if sort_order # eagerly — the enumerator below is lazy

        hint = truncated_hint(sort_order)
        Http::Pagination.by_offset(page_size: page_size, truncated_hint: hint) do |page_index, size|
          body = query_metadata_page(
            filters: filters, page_offset: page_index, page_size: size, sort_order: sort_order
          )
          Http::Pagination::OffsetPage.new(items: body["invoices"] || body["items"] || [], has_more: body["hasMore"],
                                           truncated: body["isTruncated"])
        end
      end

      # A single metadata query page (gives access to isTruncated/hasMore/permanentStorageHwmDate).
      # @return [Hash] raw page response
      def query_metadata_page(filters:, page_offset: 0, page_size: 250, sort_order: nil)
        query = { "pageOffset" => page_offset, "pageSize" => page_size }
        query["sortOrder"] = validate_sort_order(sort_order) if sort_order
        post(QUERY_METADATA, json: filters, query: query, returns: [])
      end

      private

      # The next query of a truncated result starts at the last record's date — `from` ascending, `to`
      # descending — from page 0.
      def truncated_hint(sort_order)
        bound = sort_order.to_s == "Desc" ? "to" : "from"
        "query again with dateRange.#{bound} set to the last record's date (of dateRange.dateType), from page 0"
      end

      def validate_sort_order(value)
        return value.to_s if SORT_ORDERS.include?(value.to_s)

        raise ConfigurationError, "sort_order must be one of #{SORT_ORDERS.join('/')}, got #{value.inspect}"
      end
    end
  end
end
