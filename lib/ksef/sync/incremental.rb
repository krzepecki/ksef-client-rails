# frozen_string_literal: true

require "time"

module Ksef
  module Sync
    # Incremental invoice download by HWM on top of export: adjacent PermanentStorage windows, continuing
    # from `lastPermanentStorageDate` (truncated) or `permanentStorageHwmDate` until caught up. A start
    # more than {MAX_WINDOW} back is walked in closed windows of that length (`dateRange` allows 100 days).
    class Incremental
      # Subject types a sync can run as, each with its own instance and HWM (SubjectAuthorized is left out,
      # as in the SDK examples).
      SUBJECT_TYPES = %w[Subject1 Subject2 Subject3].freeze
      # Longest closed window (s), kept under the 100-day `dateRange` limit.
      MAX_WINDOW = 90 * 86_400
      # Export status: `dateRange.from` is past `PermanentStorageHwmDate` — nothing to fetch yet.
      CODE_FROM_AFTER_HWM = 420
      # The zone a String `from` must end with (`Z` or an offset); without one KSeF assumes Warsaw time.
      ZONE = /(?:Z|[+-]\d{2}:?\d{2})\z/i

      # @return [String] where the next window starts, once every invoice yielded so far is stored — persist
      #   it and pass it as +from:+ next run. It is also safe to persist after an exception, as long as each
      #   invoice was stored before the block returned (not buffered, e.g. by `each_slice`).
      attr_reader :hwm

      # @param client [Ksef::Client]
      # @param subject_type [String] role of the downloader (Subject1/2/3)
      # @param from [String, Time, Date] initial HWM: ISO 8601 with a zone (`Z` or an offset), a Time, or a
      #   Date (midnight in Poland) — required, `dateRange.from` has no API default
      # @param page_limit [Integer] the most windows (exports) per call; KSeF allows 20 exports an hour, shared
      #   by every sync of the context
      # @param poll [Hash] polling options for each export (timeout:, interval:, ...)
      # @param clock [#call] current time source (for tests)
      # @raise [Ksef::ConfigurationError] when +from+ is missing or not a date-time with a zone
      def initialize(client, from:, subject_type: "Subject2", page_limit: 1000, poll: {}, clock: -> { Time.now })
        @client = client
        @subject_type = subject_type
        @hwm = normalize_from(from)
        @page_limit = page_limit
        @poll = poll
        @clock = clock
        @boundary = Set.new
      end

      # Iterates over invoices window by window. Boundaries are inclusive, so the previous window's
      # invoices are skipped; the first window of a new run may repeat the previous run's last ones —
      # store invoices idempotently by KSeF number. Calling it again resumes from {#hwm}.
      #
      # @yieldparam xml [String] invoice XML (UTF-8)
      # @yieldparam metadata [Hash] its InvoiceMetadata entry from `_metadata.json` (only `ksefNumber`, taken
      #   from the file name, when absent)
      # @return [Integer] number of (unique) invoices yielded
      # @raise [Ksef::RateLimited] when the hourly export limit is spent — {#hwm} is where to resume
      # @raise [Ksef::Error] when a truncated window cannot move forward
      def each_invoice(&block)
        return enum_for(:each_invoice) unless block_given?

        emitted = 0
        @page_limit.times do
          to = window_end(@hwm)
          result = export_window(@hwm, to)
          break unless result

          emitted += emit_entries(result, &block)
          next_hwm = next_window_start(result.package || {}, to)
          break unless next_hwm

          @hwm = next_hwm
        end
        emitted
      end

      private

      def normalize_from(value)
        raise ConfigurationError, "from: is required (dateRange.from is mandatory in the API)" if value.nil?
        return value.getutc.iso8601(3) if value.is_a?(Time)
        return PolishTime.midnight(value).getutc.iso8601(3) if value.instance_of?(Date)
        return value.to_time.getutc.iso8601(3) if value.respond_to?(:to_time) && !value.is_a?(String)

        text = value.to_s
        return text if text.match?(ZONE) && iso8601?(text)

        raise ConfigurationError, "from: must be an ISO 8601 date-time with a zone (e.g. 2026-10-01T00:00:00Z), " \
                                  "got #{value.inspect}"
      end

      def iso8601?(text)
        Time.iso8601(text)
        true
      rescue ArgumentError
        false
      end

      # nil leaves `dateRange.to` out (the API takes "now", capped at the HWM); a start older than
      # {MAX_WINDOW} gets a closed window instead, because the API refuses ranges over 100 days.
      def window_end(from)
        limit = Time.iso8601(from) + MAX_WINDOW
        limit < @clock.call ? limit.utc.iso8601(3) : nil
      rescue ArgumentError # a server date in an unexpected format: leave the window open
        nil
      end

      # @return [Ksef::Invoices::Export::Result, nil] nil when the HWM has not reached +from+ yet (420)
      def export_window(from, to)
        range = { "dateType" => "PermanentStorage", "from" => from, "restrictToPermanentStorageHwmDate" => true }
        range["to"] = to if to
        Invoices::Export.new(@client).call(filters: { "subjectType" => @subject_type, "dateRange" => range },
                                           poll: @poll)
      rescue ApiError => e
        raise unless e.codes.include?(CODE_FROM_AFTER_HWM)

        nil
      end

      # Yields the window's invoices with their metadata, one file at a time. Invoice files are named
      # `{ksefNumber}.xml`; `_metadata.json` entries carry the `ksefNumber` they belong to.
      def emit_entries(result)
        metadata = result.metadata.to_h { |entry| [entry["ksefNumber"], entry] }
        window = Set.new
        count = 0
        result.each_entry do |name, bytes|
          next unless name.end_with?(".xml") # `_metadata.json` and anything else that is no invoice

          ksef_number = File.basename(name, ".xml")
          repeated = @boundary.include?(ksef_number) || window.include?(ksef_number)
          window << ksef_number
          next if repeated

          count += 1
          entry = metadata.fetch(ksef_number) { { "ksefNumber" => ksef_number } }
          yield(bytes.force_encoding(Encoding::UTF_8), entry)
        end
        @boundary = window
        count
      end

      # The next window's `from` per the isTruncated rule, or nil once the sync has caught up (an
      # empty window, or an HWM that did not advance — the window then only repeated its boundary).
      # A closed window continues where it ended, even when empty: at `to`, or at the HWM if lower.
      def next_window_start(package, to)
        if package["isTruncated"]
          last = package["lastPermanentStorageDate"]
          return last if later?(last, @hwm)

          raise Error, "Export window truncated at #{last.inspect} without moving past #{@hwm.inspect}"
        end

        hwm = package["permanentStorageHwmDate"]
        if to
          ended = hwm && later?(to, hwm) ? hwm : to
          return later?(ended, @hwm) ? ended : nil
        end
        return nil if hwm.nil? || Array(package["parts"]).empty? || package["invoiceCount"]&.zero?

        hwm if later?(hwm, @hwm)
      end

      # Compares instants, not strings — the caller's `from` and the server's dates differ in format.
      def later?(candidate, current)
        return false if candidate.nil?

        Time.iso8601(candidate) > Time.iso8601(current)
      rescue ArgumentError
        candidate.to_s > current.to_s
      end
    end
  end
end
