# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Http::Pagination do
  describe ".by_offset" do
    it "iterates pages incrementing the index by 1 until has_more=false" do
      pages = [
        described_class::OffsetPage.new(items: [1, 2], has_more: true),
        described_class::OffsetPage.new(items: [3, 4], has_more: true),
        described_class::OffsetPage.new(items: [5], has_more: false)
      ]
      seen_indexes = []
      result = described_class.by_offset(page_size: 2) do |page_index, _size|
        seen_indexes << page_index
        raise "the page index does not advance: #{seen_indexes}" if seen_indexes.size > pages.size

        pages[page_index]
      end.to_a

      expect(result).to eq([1, 2, 3, 4, 5])
      expect(seen_indexes).to eq([0, 1, 2])
    end

    it "is lazy — fetches only as many pages as .first(n) needs" do
      calls = 0
      enum = described_class.by_offset(page_size: 2) do |page_index, _size|
        calls += 1
        described_class::OffsetPage.new(items: [page_index * 10, (page_index * 10) + 1], has_more: true)
      end
      expect(enum.first(3)).to eq([0, 1, 10])
      expect(calls).to eq(2)
    end

    it "raises ResultTruncated once a truncated page is consumed, instead of asking for the next index" do
      requested = []
      enum = described_class.by_offset(page_size: 2) do |page_index, _size|
        requested << page_index
        described_class::OffsetPage.new(items: [{ "n" => page_index }], has_more: true, truncated: page_index == 1)
      end

      expect(enum.first(2)).to eq([{ "n" => 0 }, { "n" => 1 }])
      expect { enum.to_a }.to raise_error(Ksef::ResultTruncated) { |error| expect(error.last_item).to eq("n" => 1) }
      expect(requested.max).to eq(1)
    end

    it "stops on an empty page even when the server still claims has_more" do
      calls = 0
      result = described_class.by_offset(page_size: 2) do |page_index, _size|
        calls += 1
        described_class::OffsetPage.new(items: page_index.zero? ? [1] : [], has_more: true)
      end.to_a

      expect(result).to eq([1])
      expect(calls).to eq(2)
    end
  end

  describe ".by_continuation" do
    it "passes the body token into the next request until it disappears" do
      responses = {
        nil => described_class::ContinuationPage.new(items: %w[a b], continuation_token: "t1"),
        "t1" => described_class::ContinuationPage.new(items: %w[c], continuation_token: "t2"),
        "t2" => described_class::ContinuationPage.new(items: %w[d], continuation_token: nil)
      }
      tokens = []
      result = described_class.by_continuation(page_size: 2) do |token, _size|
        tokens << token
        responses[token]
      end.to_a

      expect(result).to eq(%w[a b c d])
      expect(tokens).to eq([nil, "t1", "t2"])
    end

    it "follows a token through empty pages but stops when the token repeats" do
      responses = {
        nil => described_class::ContinuationPage.new(items: [], continuation_token: "t1"),
        "t1" => described_class::ContinuationPage.new(items: %w[a], continuation_token: "t1")
      }
      calls = 0
      result = described_class.by_continuation(page_size: 2) do |token, _size|
        calls += 1
        responses.fetch(token)
      end.to_a

      expect(result).to eq(%w[a])
      expect(calls).to eq(2)
    end

    it "stops when a token comes back after another one (a cycle)" do
      responses = {
        nil => described_class::ContinuationPage.new(items: %w[a], continuation_token: "A"),
        "A" => described_class::ContinuationPage.new(items: %w[b], continuation_token: "B"),
        "B" => described_class::ContinuationPage.new(items: %w[c], continuation_token: "A")
      }
      tokens = []
      result = described_class.by_continuation(page_size: 2) do |token, _size|
        tokens << token
        raise "looping: #{tokens}" if tokens.size > 5

        responses.fetch(token)
      end.to_a

      expect(result).to eq(%w[a b c])
      expect(tokens).to eq([nil, "A", "B"])
    end

    it "raises after too many empty pages in a row" do
      calls = 0
      enum = described_class.by_continuation(page_size: 2) do |_token, _size|
        calls += 1
        described_class::ContinuationPage.new(items: [], continuation_token: "t#{calls}")
      end

      expect { enum.to_a }.to raise_error(Ksef::Error, /empty pages in a row/)
      expect(calls).to eq(described_class::MAX_EMPTY_PAGES)
    end
  end

  describe "the truncated-result hint of Invoices#query_metadata" do
    let(:client) { test_client(access_token: "acc") }

    it "names the dateRange bound to move for the sort order" do
      stub_request(:post, %r{/invoices/query/metadata}).to_return(
        status: 200, body: JSON.generate("invoices" => [{ "ksefNumber" => "1" }], "hasMore" => true,
                                         "isTruncated" => true)
      )

      { nil => /dateRange.from/, "Asc" => /dateRange.from/, "Desc" => /dateRange.to set/ }.each do |order, hint|
        expect { client.invoices.query_metadata(filters: {}, sort_order: order).to_a }
          .to raise_error(Ksef::ResultTruncated, hint)
      end
    end
  end
end
