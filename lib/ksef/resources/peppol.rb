# frozen_string_literal: true

module Ksef
  module Resources
    # Peppol resource — the /peppol/query endpoint: the list of Peppol providers. Anonymous, as the
    # contract declares (confirmed on TEST, DEMO and PROD with 2.8.1).
    class Peppol < Base
      QUERY = "/peppol/query"

      # GET /peppol/query — list of Peppol providers (offset pagination).
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>] provider entries ({ "id", "name", "dateCreated" })
      def query(page_size: 10)
        Http::Pagination.by_offset(page_size: page_size) do |page, size|
          data = get(QUERY, bearer: nil, query: { "pageOffset" => page, "pageSize" => size }, returns: [])
          Http::Pagination::OffsetPage.new(items: data["peppolProviders"] || [], has_more: data["hasMore"])
        end
      end
    end
  end
end
