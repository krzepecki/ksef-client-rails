# frozen_string_literal: true

# Batch session: N copies of the invoice on Issue invoice (unique numbers) in one ZIP/tar.gz package,
# split into encrypted parts, uploaded to presigned URLs. Processing is asynchronous — the result
# links to the session page for status and UPO.
class BatchesController < ApplicationController
  before_action :describe_base

  def index; end

  def create
    ksef_action("Batch session") do
      count = params[:count].to_i.clamp(1, 50)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      invoices = Array.new(count) { |i| ["invoice-#{i + 1}.xml", copy("FV/BATCH/#{stamp}/#{i + 1}")] }.to_h
      compression = params[:compression] == "tar_gz" ? :tar_gz : :zip
      part_size = (params[:part_kb].to_i * 1024).clamp(1024, Ksef::Batch::Splitter::MAX_PART_SIZE)
      result = Ksef::Batch::Uploader.new(authed_client, part_size: part_size)
                                    .call(invoices: invoices, compression: compression)
      @session_reference = result.reference_number
      {
        "session" => result.reference_number, "invoices" => count, "compression" => compression.to_s,
        "package size" => "#{result.parts.sum(&:plain_size)} B",
        "parts" => result.parts.map do |p|
          { "ordinal" => p.ordinal_number, "encrypted size" => p.encrypted_size }
        end
      }
    end
  end

  private

  # The page names the invoice that "Send batch" copies — the one Issue invoice shows.
  def describe_base
    @base_source = if saved_invoice_xml
                     session[:invoice_tab] == "schema" ? "the “All fields” tab" : "the “XML” tab"
                   else
                     session[:draft].present? ? "the Typical/Full form" : "the sample invoice"
                   end
    @base_summary = summary(Nokogiri::XML(saved_invoice_xml || saved_draft.to_xml).tap(&:remove_namespaces!))
  rescue Ksef::ConfigurationError, Ksef::SchemaValidationError => e
    @base_summary = { "error" => "#{e.message} — fix it on Issue invoice" }
  end

  def summary(doc)
    text = ->(*paths) { paths.filter_map { |path| doc.at_xpath(path)&.text }.join(" · ") }
    {
      "seller" => text.call("//Podmiot1//Nazwa", "//Podmiot1//NIP"),
      "buyer" => text.call("//Podmiot2//Nazwa", "//Podmiot2//NIP"),
      "lines" => doc.xpath("//FaWiersz").size,
      "gross (P_15)" => text.call("//Fa/P_15", "//Fa/KodWaluty")
    }
  end

  # One copy numbered `number`: the XML tab's document with its P_2 replaced, or the form draft.
  def copy(number)
    return saved_draft.tap { |draft| draft.number = number }.to_xml unless (xml = saved_invoice_xml)

    doc = Nokogiri::XML(xml)
    p2 = doc.at_xpath("//*[local-name()='Fa']/*[local-name()='P_2']")
    raise ArgumentError, "The invoice from Issue invoice has no Fa/P_2 to number the copies by" unless p2

    p2.content = number
    doc.to_xml.tap { |copy| Ksef::Invoices::Validator.new(form_code: Ksef::FormCode::FA3).validate!(copy) }
  end
end
