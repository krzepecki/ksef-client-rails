# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::PolishTime do
  it "switches to CEST at 01:00 UTC on the last Sunday of March and back on the last Sunday of October" do
    { Time.utc(2026, 3, 29, 0, 59) => 3600, Time.utc(2026, 3, 29, 1) => 7200,
      Time.utc(2026, 10, 25, 0, 59) => 7200, Time.utc(2026, 10, 25, 1) => 3600,
      Time.utc(2027, 3, 28, 1) => 7200, Time.utc(2026, 1, 1) => 3600 }.each do |utc, offset|
      expect(described_class.offset(utc)).to eq(offset), utc.to_s
    end
  end

  it "gives the Polish calendar day, which a UTC or a far-east host would get wrong" do
    expect(described_class.today(Time.utc(2026, 10, 12, 22, 30))).to eq(Date.new(2026, 10, 13))
    expect(described_class.today(Time.utc(2026, 12, 31, 22, 59))).to eq(Date.new(2026, 12, 31))
    expect(described_class.today(Time.new(2026, 10, 13, 8, 0, 0, "+14:00"))).to eq(Date.new(2026, 10, 12))
  end

  it "gives midnight in Poland, on both transition days too" do
    expect(described_class.midnight(Date.new(2026, 1, 5)).utc).to eq(Time.utc(2026, 1, 4, 23))
    expect(described_class.midnight(Date.new(2026, 3, 29)).utc).to eq(Time.utc(2026, 3, 28, 23))
    expect(described_class.midnight(Date.new(2026, 3, 30)).utc).to eq(Time.utc(2026, 3, 29, 22))
    expect(described_class.midnight(Date.new(2026, 10, 25)).utc).to eq(Time.utc(2026, 10, 24, 22))
    expect(described_class.midnight(Date.new(2026, 10, 26)).utc).to eq(Time.utc(2026, 10, 25, 23))
    expect(described_class.at(Time.utc(2026, 7, 1, 12)).utc_offset).to eq(7200)
  end
end
