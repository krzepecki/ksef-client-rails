# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::KsefNumber do
  # Fictitious NIP; the checksum was computed with an independent CRC-8 implementation (Python),
  # cross-checked against the official example in the KSeF docs (faktury/numer-ksef.md).
  let(:valid_number) { "5555555555-20250826-0100001AF629-72" }

  it "validates a correct number (CRC-8 poly 0x07)" do
    expect(described_class.new(valid_number).valid?).to be(true)
  end

  it "rejects a number with a bad checksum" do
    expect(described_class.new("5555555555-20250826-0100001AF629-00").valid?).to be(false)
  end

  it "rejects a number of the wrong length" do
    expect(described_class.new("123").valid?).to be(false)
  end

  it "computes CRC-8 over everything before the last hyphen" do
    expect(described_class.crc8("5555555555-20250826-0100001AF629")).to eq(0x72)
  end

  it "accepts the official example number (numer-ksef.md), whose CRC-8 is AF" do
    expect(described_class.crc8("5265877635-20250826-0100001AF629")).to eq(0xAF)
    expect(described_class.new("5265877635-20250826-0100001AF629-AF")).to be_valid
  end

  it "is equal only to another KsefNumber, symmetrically" do
    number = described_class.new(valid_number)

    expect([number == described_class.new(valid_number), number == valid_number, valid_number == number])
      .to eq([true, false, false])
  end

  it "extracts the seller tax identification number" do
    expect(described_class.new(valid_number).seller_nip).to eq("5555555555")
  end

  it "validate! raises for an invalid number" do
    expect { described_class.new("bad").validate! }.to raise_error(Ksef::ConfigurationError)
  end

  it "rejects what the contract pattern rejects, even with a matching CRC" do
    lowercase = "5555555555-20250826-0100001af629"
    filler = "x" * 32
    [lowercase, filler, "0555555555-20250826-0100001AF629"].each do |data|
      number = "#{data}-#{format('%02X', described_class.crc8(data))}"
      expect(described_class.new(number).valid?).to be(false), number
    end
  end

  it "accepts the 36-character form with a hyphen inside the hex part" do
    data = "5555555555-20250826-010000-1AF629"
    expect(described_class.new("#{data}-#{format('%02X', described_class.crc8(data))}").valid?).to be(true)
  end
end

RSpec.describe Ksef::Nip do
  it "accepts a valid tax identification number (mod 11)" do
    expect(described_class.new("5555555555").valid?).to be(true)
  end

  it "strips separators" do
    expect(described_class.new("526-587-76-35").valid?).to be(true)
  end

  it "strips the PL prefix of an EU VAT number" do
    expect(described_class.new("PL 526-025-02-74").value).to eq("5260250274")
    expect(described_class.new("pl5260250274").valid?).to be(true)
  end

  it "rejects a number with a bad check digit" do
    expect(described_class.new("1234567890").valid?).to be(false)
  end

  it "rejects a number of the wrong length" do
    expect(described_class.new("123").valid?).to be(false)
  end

  it "normalize! returns the digits of a valid number and raises for an invalid one" do
    expect(described_class.normalize!("PL 526-025-02-74")).to eq("5260250274")
    expect(described_class.normalize!(described_class.new("5555555555"))).to eq("5555555555")
    expect { described_class.normalize!("1234567890", name: "seller_nip") }
      .to raise_error(Ksef::ConfigurationError, /seller_nip is not a valid NIP: "1234567890"/)
  end

  it "strips no-break spaces and dashes, and shows them escaped in the error" do
    expect(described_class.normalize!("526\u00A0025\u201302\u201174")).to eq("5260250274")
    expect { described_class.normalize!("123\u00A0456") }.to raise_error(Ksef::ConfigurationError, /\\u00A0/)
  end

  it "is equal only to another Nip, symmetrically, and so deduplicates consistently" do
    nip = described_class.new("5555555555")

    expect([nip == described_class.new("555-555-55-55"), nip == "5555555555", "5555555555".eql?(nip)])
      .to eq([true, false, false])
    expect([nip, described_class.new("5555555555"), "5555555555"].uniq.size).to eq(2)
  end

  it "rejects numbers the contract pattern excludes, although their check digit matches" do
    %w[0000000000 0123456789 1000000006].each do |nip|
      expect(described_class.new(nip).valid?).to be(false), nip
    end
  end
end

RSpec.describe Ksef::FormCode do
  it "serializes FA(3) to the API contract" do
    expect(described_class::FA3.to_h).to eq(
      "systemCode" => "FA (3)", "schemaVersion" => "1-0E", "value" => "FA"
    )
  end

  it "names the PEF forms PEF (3) and PEF_KOR (3)" do
    expect(described_class::PEF3.system_code).to eq("PEF (3)")
    expect(described_class::PEF_KOR3.system_code).to eq("PEF_KOR (3)")
  end
end
