# frozen_string_literal: true

require "date"

module Ksef
  # The Europe/Warsaw calendar, which KSeF dates follow (e.g. an invoice's `P_1`), without tzinfo: CET
  # (+01:00), and CEST (+02:00) from 01:00 UTC on the last Sunday of March to 01:00 UTC on the last
  # Sunday of October — the EU rule.
  module PolishTime
    module_function

    # @param now [Time]
    # @return [Date] the current calendar day in Poland
    def today(now = Time.now)
      at(now).to_date
    end

    # @param time [Time]
    # @return [Time] the same instant with the Polish UTC offset
    def at(time)
      utc = time.getutc
      utc.getlocal(offset(utc))
    end

    # @param date [Date]
    # @return [Time] midnight in Poland at the start of the day
    def midnight(date)
      utc = Time.utc(date.year, date.month, date.day)
      offset = offset(utc - 3600)
      (utc - offset).getlocal(offset)
    end

    # @param utc [Time]
    # @return [Integer] the Polish UTC offset in seconds at that instant
    def offset(utc)
      summer_start = switch(utc.year, 3)
      summer_end = switch(utc.year, 10)
      utc >= summer_start && utc < summer_end ? 7200 : 3600
    end

    # 01:00 UTC on the last Sunday of the month.
    def switch(year, month)
      last = Date.new(year, month, -1)
      sunday = last - last.wday
      Time.utc(year, month, sunday.day, 1)
    end
    private_class_method :switch
  end
end
