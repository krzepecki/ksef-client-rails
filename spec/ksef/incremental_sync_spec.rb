# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Sync::Incremental do
  let(:client) { test_client(access_token: "acc") }
  let(:exporter) { instance_double(Ksef::Invoices::Export) }
  let(:windows) { [] }
  let(:export_options) { [] }
  # "Now" for the windows below, so that they are recent (open-ended) rather than older than 90 days.
  let(:now) { Time.utc(2026, 1, 10) }

  before do
    allow(Ksef::Invoices::Export).to receive(:new).with(client).and_return(exporter)
    allow(exporter).to receive(:call) do |filters:, **options|
      windows << filters
      export_options << options
      results.fetch(windows.size - 1) { raise "unexpected export window #{windows.size}" }
    end
  end

  def sync(**options) = described_class.new(client, clock: -> { now }, **options)

  def number(seq) = "5555555555-20260101-#{format('%012X', seq)}-00"

  # An export package holding `{ksefNumber}.xml` files plus their `_metadata.json`, as KSeF builds it.
  def window(*seqs, truncated: false, hwm: nil, last: nil)
    metadata = seqs.map { |seq| { "ksefNumber" => number(seq), "invoiceNumber" => "FV/#{seq}" } }
    files = seqs.to_h { |seq| ["#{number(seq)}.xml", "<Faktura>#{seq} zażółć</Faktura>"] }
    files["_metadata.json"] = JSON.generate("invoices" => metadata)
    package = { "isTruncated" => truncated, "permanentStorageHwmDate" => hwm, "invoiceCount" => seqs.size,
                "parts" => [{ "ordinalNumber" => 1 }] }
    package["lastPermanentStorageDate"] = last if last
    Ksef::Invoices::Export::Result.new(bytes: Ksef::Batch::PackageBuilder.zip(files).bytes, package: package)
  end

  # The same window packed as tar.gz with "./" names and a stray non-invoice file.
  def dotted_tar_gz_window(seq, hwm:)
    metadata = JSON.generate("invoices" => [{ "ksefNumber" => number(seq), "invoiceNumber" => "FV/#{seq}" }])
    files = { "./#{number(seq)}.xml" => "<Faktura>#{seq}</Faktura>", "./README.txt" => "not an invoice",
              "./_metadata.json" => metadata }
    package = { "isTruncated" => false, "permanentStorageHwmDate" => hwm, "invoiceCount" => 1,
                "parts" => [{ "ordinalNumber" => 1 }] }
    Ksef::Invoices::Export::Result.new(bytes: Ksef::Batch::PackageBuilder.tar_gz(files).bytes, package: package)
  end

  def empty_window(hwm:)
    Ksef::Invoices::Export::Result.new(bytes: "".b, package: { "isTruncated" => false, "invoiceCount" => 0,
                                                               "permanentStorageHwmDate" => hwm, "parts" => [] })
  end

  def from_of(filters) = filters.dig("dateRange", "from")

  context "with windows that move forward" do
    let(:results) do
      [
        window(1, 2, truncated: true, last: "2026-01-05T10:00:00.000+00:00", hwm: "2026-01-09T00:00:00.000+00:00"),
        window(2, 3, hwm: "2026-01-09T00:00:00.000+00:00"),
        empty_window(hwm: "2026-01-09T00:00:00.000+00:00")
      ]
    end

    it "pairs every invoice with its metadata, skips the boundary repeat and stops on an empty window" do
      yielded = []
      count = sync(from: "2026-01-01T00:00:00Z").each_invoice do |xml, meta|
        yielded << [xml, meta]
      end

      expect(count).to eq(3)
      expect(yielded.map { |_, meta| meta["invoiceNumber"] }).to eq(%w[FV/1 FV/2 FV/3])
      expect(yielded.map { |xml, _| xml.encoding }.uniq).to eq([Encoding::UTF_8])
      expect(yielded.first.first).to eq("<Faktura>1 zażółć</Faktura>")
    end

    it "continues from lastPermanentStorageDate, then permanentStorageHwmDate, and exposes the HWM" do
      sync = sync(from: "2026-01-01T00:00:00Z", subject_type: "Subject1")
      sync.each_invoice { |_xml, _meta| nil }

      expect(windows.map { |filters| from_of(filters) })
        .to eq(["2026-01-01T00:00:00Z", "2026-01-05T10:00:00.000+00:00", "2026-01-09T00:00:00.000+00:00"])
      expect(windows.first).to eq("subjectType" => "Subject1",
                                  "dateRange" => { "dateType" => "PermanentStorage", "from" => "2026-01-01T00:00:00Z",
                                                   "restrictToPermanentStorageHwmDate" => true })
      expect(sync.hwm).to eq("2026-01-09T00:00:00.000+00:00")
    end
  end

  context "with a tar.gz package whose names start with ./" do
    let(:results) { [dotted_tar_gz_window(7, hwm: "2026-01-02T00:00:00Z"), empty_window(hwm: "2026-01-02T00:00:00Z")] }

    it "pairs the invoice with its metadata and yields nothing but invoices" do
      yielded = []
      sync(from: "2026-01-01T00:00:00Z").each_invoice { |xml, meta| yielded << [xml, meta] }

      expect(yielded).to eq([["<Faktura>7</Faktura>", { "ksefNumber" => number(7), "invoiceNumber" => "FV/7" }]])
    end
  end

  context "when the HWM does not advance (the window only repeats its boundary)" do
    let(:results) do
      [window(1, hwm: "2026-01-02T00:00:00Z"), window(1, hwm: "2026-01-02T00:00:00.000+00:00")]
    end

    it "stops after that window instead of exporting it again and again" do
      sync = sync(from: "2026-01-01T00:00:00Z")

      expect(sync.each_invoice { |_xml, _meta| nil }).to eq(1)
      expect(windows.size).to eq(2)
      expect(sync.hwm).to eq("2026-01-02T00:00:00Z")
    end
  end

  context "when a truncated window cannot move forward" do
    let(:results) { [window(1, truncated: true, last: "2026-01-01T00:00:00.000+00:00")] }

    it "raises instead of dropping the invoices beyond the truncation" do
      expect { sync(from: "2026-01-01T00:00:00Z").each_invoice { |_xml, _meta| nil } }
        .to raise_error(Ksef::Error, /truncated/)
    end
  end

  context "with a page limit" do
    let(:results) do
      [window(1, hwm: "2026-01-02T00:00:00Z"), window(2, hwm: "2026-01-03T00:00:00Z"),
       window(3, hwm: "2026-01-04T00:00:00Z"), empty_window(hwm: "2026-01-04T00:00:00Z")]
    end

    it "stops at the limit, and a second call resumes from the HWM without repeating the boundary" do
      sync = sync(from: "2026-01-01T00:00:00Z", page_limit: 2)

      expect(sync.each_invoice { |_xml, _meta| nil }).to eq(2)
      expect(sync.hwm).to eq("2026-01-03T00:00:00Z")
      expect(sync.each_invoice { |_xml, _meta| nil }).to eq(1)
      expect(windows.map { |filters| from_of(filters) }.last(2)).to eq(%w[2026-01-03T00:00:00Z 2026-01-04T00:00:00Z])
    end
  end

  context "with a start older than the 100-day dateRange limit" do
    let(:results) do
      [empty_window(hwm: "2025-08-30T00:00:00.000Z"), empty_window(hwm: "2025-11-28T00:00:00.000Z"),
       window(1, hwm: "2026-01-09T00:00:00Z"), empty_window(hwm: "2026-01-09T00:00:00Z")]
    end

    it "walks closed windows of 90 days, continuing past empty ones, then one open window" do
      sync = sync(from: "2025-06-01T00:00:00Z")

      expect(sync.each_invoice { |_xml, _meta| nil }).to eq(1)
      expect(windows.map { |filters| filters["dateRange"].slice("from", "to") }).to eq(
        [{ "from" => "2025-06-01T00:00:00Z", "to" => "2025-08-30T00:00:00.000Z" },
         { "from" => "2025-08-30T00:00:00.000Z", "to" => "2025-11-28T00:00:00.000Z" },
         { "from" => "2025-11-28T00:00:00.000Z" },
         { "from" => "2026-01-09T00:00:00Z" }]
      )
      expect(sync.hwm).to eq("2026-01-09T00:00:00Z")
    end
  end

  context "with a closed window whose HWM stays below its end" do
    let(:now) { Time.utc(2026, 1, 10, 0, 1) }
    let(:results) { [empty_window(hwm: "2026-01-09T23:58:00Z"), empty_window(hwm: "2026-01-09T23:58:00Z")] }

    it "continues from the HWM, not from the window end, so nothing between them is skipped" do
      sync(from: "2025-10-12T00:00:00Z").each_invoice { |_xml, _meta| nil }

      expect(windows.first["dateRange"]["to"]).to eq("2026-01-10T00:00:00.000Z")
      expect(windows.last["dateRange"]).not_to have_key("to")
      expect(windows.last["dateRange"]["from"]).to eq("2026-01-09T23:58:00Z")
    end
  end

  context "when from is past the HWM (export status 420)" do
    let(:results) { [] }

    it "has nothing to fetch yet and keeps from as the HWM" do
      allow(exporter).to receive(:call).and_raise(Ksef::ApiError.new("Zakres filtrowania", codes: [420]))
      sync = sync(from: "2026-01-09T23:59:00Z")

      expect(sync.each_invoice { |_xml, _meta| nil }).to eq(0)
      expect(sync.hwm).to eq("2026-01-09T23:59:00Z")
    end
  end

  context "with polling options" do
    let(:results) { [empty_window(hwm: "2026-01-02T00:00:00Z")] }

    it "passes them to every export" do
      sync(from: "2026-01-01T00:00:00Z", poll: { timeout: 900 }).each_invoice { |_xml, _meta| nil }

      expect(export_options).to eq([{ poll: { timeout: 900 } }])
    end
  end

  context "with from given as a Time or without a zone" do
    let(:results) { [] }

    it "normalizes a Time to UTC without touching it, and refuses a string without a zone" do
      local = Time.new(2026, 1, 5, 12, 0, 0, "+01:00")

      expect(sync(from: local).hwm).to eq("2026-01-05T11:00:00.000Z")
      expect(local.utc_offset).to eq(3600)
      ["2026-01-05T12:00:00", "yesterday"].each do |from|
        expect { sync(from: from) }.to raise_error(Ksef::ConfigurationError, /zone/)
      end
    end

    it "starts a Date at midnight in Poland, in winter and in summer" do
      expect(sync(from: Date.new(2026, 1, 5)).hwm).to eq("2026-01-04T23:00:00.000Z")
      expect(sync(from: Date.new(2026, 7, 5)).hwm).to eq("2026-07-04T22:00:00.000Z")
    end
  end

  context "with an invoice missing from _metadata.json" do
    let(:results) do
      files = { "#{number(1)}.xml" => "<Faktura>1</Faktura>", "_metadata.json" => JSON.generate("invoices" => []) }
      [Ksef::Invoices::Export::Result.new(bytes: Ksef::Batch::PackageBuilder.zip(files).bytes,
                                          package: { "isTruncated" => false, "invoiceCount" => 1, "parts" => [{}],
                                                     "permanentStorageHwmDate" => "2026-01-02T00:00:00Z" }),
       empty_window(hwm: "2026-01-02T00:00:00Z")]
    end

    it "still yields its KSeF number, from the file name" do
      yielded = []
      sync(from: "2026-01-01T00:00:00Z").each_invoice { |_xml, meta| yielded << meta }

      expect(yielded).to eq([{ "ksefNumber" => number(1) }])
    end
  end

  context "when the hourly export limit is spent" do
    let(:results) { [window(1, 2, truncated: true, last: "2026-01-05T10:00:00Z", hwm: "2026-01-09T00:00:00Z")] }

    it "raises RateLimited with the HWM at the start of the window it could not export" do
      allow(exporter).to receive(:call) do |filters:, **|
        windows << filters
        raise Ksef::RateLimited.new("limit", status: 429, retry_after: 3600) if windows.size > 1

        results.first
      end
      sync = sync(from: "2026-01-01T00:00:00Z")
      stored = []

      expect { sync.each_invoice { |xml, _meta| stored << xml } }.to raise_error(Ksef::RateLimited)
      expect([stored.size, sync.hwm]).to eq([2, "2026-01-05T10:00:00Z"])
    end
  end

  context "without a block" do
    let(:results) { [empty_window(hwm: "2026-01-02T00:00:00Z")] }

    it "returns an enumerator and requires from:" do
      expect(sync(from: "2026-01-01T00:00:00Z").each_invoice).to be_a(Enumerator)
      expect { described_class.new(client, from: nil) }.to raise_error(Ksef::ConfigurationError, /from:/)
    end
  end
end
