# frozen_string_literal: true

# Invoice package export (encrypted, split, hash-checked, decrypted, unpacked by the gem; ZIP or
# tar.gz) and the incremental HWM sync built on top of it.
class ExportsController < ApplicationController
  POLL = { interval: 3, timeout: 180 }.freeze
  # Package format → download file extension.
  EXTENSIONS = { zip: "zip", tar_gz: "tar.gz" }.freeze

  def index; end

  def create
    ksef_action("Export invoices") do
      result = Ksef::Invoices::Export.new(authed_client).call(
        filters: filters, only_metadata: params[:only_metadata] == "1",
        compression_type: params[:compression_type].presence_in(Ksef::Invoices::Export::COMPRESSION_TYPES) || "Zip",
        poll: POLL
      )
      @files = result.each_entry.map { |name, bytes| { "file" => name, "size" => "#{bytes.bytesize} B" } }
      if result.compression
        name = "ksef-export-#{Time.now.strftime('%Y%m%d-%H%M%S')}.#{EXTENSIONS.fetch(result.compression)}"
        @package_path = stash(result.bytes, filename: name)
      end
      @metadata = result.metadata.first(100)
      result.package.except("parts").merge("parts" => Array(result.package["parts"]).size)
    end
  end

  # Iterates HWM windows; bounded by windows and invoices so that a demo page returns quickly.
  def sync
    ksef_action("Incremental sync") do
      limit = params[:max_invoices].to_i.clamp(1, 200)
      sync = Ksef::Sync::Incremental.new(authed_client, from: warsaw_time(params[:from], "00:00:00"),
                                                        subject_type: params[:subject_type].presence || "Subject2",
                                                        page_limit: params[:windows].to_i.clamp(1, 5))
      @synced = []
      sync.each_invoice do |xml, meta|
        @synced << { "KSeF number" => meta["ksefNumber"], "invoice number" => meta["invoiceNumber"],
                     "stored" => meta["permanentStorageDate"], "size" => "#{xml.bytesize} B" }
        break if @synced.size >= limit
      end
      { "invoices received" => @synced.size, "next run from (sync.hwm)" => sync.hwm }
    end
  end

  private

  def filters
    {
      "subjectType" => params[:subject_type].presence || "Subject1",
      "dateRange" => { "dateType" => params[:date_type].presence || "Issue",
                       "from" => warsaw_time(params[:date_from], "00:00:00"),
                       "to" => warsaw_time(params[:date_to], "23:59:59") }
    }
  end
end
