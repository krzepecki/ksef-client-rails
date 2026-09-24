# frozen_string_literal: true

module Ksef
  module Http
    # The two KSeF pagination mechanisms, split along "query vs list":
    # {.by_offset} uses `pageOffset` (a 0-based page INDEX, not a record offset) + `hasMore`;
    # {.by_continuation} reads `continuationToken` from the body but sends it in the
    # `x-continuation-token` header. Both return a lazy enumerator, so pages are fetched on demand.
    module Pagination
      # A single page of offset-paginated results; +truncated+ marks the server's record limit.
      OffsetPage = Struct.new(:items, :has_more, :truncated, keyword_init: true)
      # A single page of continuation-token-paginated results.
      ContinuationPage = Struct.new(:items, :continuation_token, keyword_init: true)
      # Empty continuation pages in a row after which iteration gives up.
      MAX_EMPTY_PAGES = 100

      module_function

      # Iterates over pages incrementing the page index by 1 while `has_more` is truthy; an empty page
      # ends the iteration too, so a server that keeps answering `hasMore` cannot loop it forever. A
      # truncated page with more behind it raises once its items are consumed: the next page index
      # would not continue the result.
      #
      # @param page_size [Integer] page size
      # @param start_page [Integer] starting page index (defaults to 0)
      # @param truncated_hint [String] how to continue past a truncated result, for the error message
      # @yieldparam page_index [Integer]
      # @yieldparam page_size [Integer]
      # @yieldreturn [OffsetPage]
      # @return [Enumerator::Lazy]
      # @raise [Ksef::ResultTruncated] when iteration goes past a truncated page
      def by_offset(page_size: 10, start_page: 0, truncated_hint: "narrow the query")
        Enumerator.new do |yielder|
          page_index = start_page
          loop do
            page = yield(page_index, page_size)
            items = Array(page.items)
            items.each { |item| yielder << item }
            break if !page.has_more || items.empty?
            if page.truncated
              raise ResultTruncated.new("The result reached the record limit (isTruncated) — #{truncated_hint}",
                                        last_item: items.last)
            end

            page_index += 1
          end
        end.lazy
      end

      # Iterates over pages passing the continuation token for as long as the server returns a new one. A
      # page may be empty and still continue; a token returned before ends the iteration (it would loop
      # forever), and so many empty pages in a row raise.
      #
      # @param page_size [Integer] page size
      # @yieldparam continuation_token [String, nil] nil on the first request
      # @yieldparam page_size [Integer]
      # @yieldreturn [ContinuationPage]
      # @return [Enumerator::Lazy]
      # @raise [Ksef::Error] after {MAX_EMPTY_PAGES} empty pages in a row
      def by_continuation(page_size: 10)
        Enumerator.new do |yielder|
          seen = Set.new
          empty = 0
          token = nil
          loop do
            page = yield(token, page_size)
            items = Array(page.items)
            items.each { |item| yielder << item }
            empty = items.empty? ? empty + 1 : 0
            raise Error, "KSeF returned #{empty} empty pages in a row; stopping" if empty >= MAX_EMPTY_PAGES

            seen << token if token
            token = page.continuation_token
            break if token.nil? || token.to_s.empty? || seen.include?(token)
          end
        end.lazy
      end
    end
  end
end
