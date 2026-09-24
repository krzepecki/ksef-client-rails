# frozen_string_literal: true

# Issuing invoices and browsing them (download by KSeF number, metadata query). Four ways to write
# the invoice — `source`: "typical" / "full" (the InvoiceDraft form), "schema" (every XSD element,
# serialized in the browser) and "xml" (raw) — then online session → UPO.
class InvoicesController < ApplicationController
  before_action { @active_nav = new_invoice_path if %w[new preview create].include?(action_name) }

  SOURCES = %w[typical full schema xml].freeze
  # What the builder refuses in a draft — shown as a form error.
  BUILD_ERRORS = [Ksef::ConfigurationError, Ksef::SchemaValidationError].freeze
  DRAFT_PARAMS = [
    :number, :issue_date, :sale_date, :place, :payment_method, :due_date, :bank_account, :bank_name, :paid,
    :paid_date, :exemption_reason, :invoice_type, :correction_reason, :correction_type, :corrected_date,
    :corrected_number, :corrected_ksef_number, :footer, :krs, :regon, :bdo,
    { seller: InvoiceDraft::PARTY_FIELDS, buyer: InvoiceDraft::PARTY_FIELDS, lines: InvoiceDraft::LINE_FIELDS,
      annotations: InvoiceDraft::ANNOTATIONS.keys }
  ].freeze

  def index; end

  def new
    @draft = saved_draft
    @tab = session[:invoice_tab]
    @xml = saved_invoice_xml
    render_new
  end

  # Validates locally and shows the XML — no call to KSeF. The schema tab comes back to itself,
  # prefilled from what it produced; the form tabs land on the XML tab to show the result.
  def preview
    @draft = draft_from_params
    remember_form
    @xml = xml_to_send
    @validation = validator.validate(@xml)
    @tab = source == "schema" ? "schema" : "xml"
    render_new
  rescue *BUILD_ERRORS => e
    render_new(error: e)
  end

  def create
    @draft = draft_from_params
    remember_form
    return render_new(alert: ApplicationController::NotAuthenticated.new.message) unless authenticated?

    @submission = InvoiceSubmission.new(ksef_client, xml_to_send, validate: params[:skip_validation] != "1").call
    remember(@submission) if @submission.success?
    @qr = qr_for(@submission.xml, @submission.ksef_number || "OFFLINE") if @submission.success?
    render :submitted
  rescue *BUILD_ERRORS => e
    render_new(error: e)
  end

  def fetch
    @ksef_number = params[:ksef_number].to_s.strip
    ksef_action("Download invoice #{@ksef_number}") do
      @invoice_xml = authed_client.invoices.get_by_ksef_number(@ksef_number)
      { "KSeF number" => @ksef_number, "size" => "#{@invoice_xml.bytesize} B" }
    end
  end

  def download
    xml = authed_client.invoices.get_by_ksef_number(params[:ksef_number])
    deliver(xml, "#{params[:ksef_number]}.xml")
  rescue StandardError => e
    redirect_to invoices_path, alert: "Download failed: #{e.message}"
  end

  def metadata
    ksef_action("Invoice metadata") do
      filters = {
        "subjectType" => params[:subject_type].presence || "Subject1",
        "dateRange" => { "dateType" => params[:date_type].presence || "Issue",
                         "from" => warsaw_time(params[:date_from], "00:00:00"),
                         "to" => warsaw_time(params[:date_to], "23:59:59") }
      }
      @invoices = authed_client.invoices.query_metadata(filters: filters, page_size: 50, sort_order: "Desc").first(50)
      { "invoices found (max 50)" => @invoices.size }
    end
  end

  private

  def draft_params
    params.fetch(:draft, {}).permit(*DRAFT_PARAMS)
  end

  # The XML tabs submit no form fields (their fieldset is disabled) — keep the last draft for them.
  def draft_from_params
    return saved_draft unless params[:draft]

    InvoiceDraft.from_params(draft_params.to_h, seller_nip: settings["nip"])
  end

  def source
    params[:source].presence_in(SOURCES) || "typical"
  end

  # The form tabs keep their fields; the XML-producing tabs keep the document itself.
  def remember_form
    session[:draft] = draft_params.to_h if params[:draft]
    session[:invoice_tab] = source
    session[:invoice_xml] = params[:invoice_xml] if %w[schema xml].include?(source)
  end

  # From the form, or the XML of the "XML"/"All fields" tabs. A demo number is refreshed on every
  # send — an identical invoice would be rejected as a duplicate (440).
  def xml_to_send
    if %w[schema xml].include?(source) && params[:invoice_xml].present?
      xml = source == "schema" ? indent(params[:invoice_xml]) : params[:invoice_xml]
      xml.sub(%r{<P_2>FV/DEMO/[^<]*</P_2>}, "<P_2>#{InvoiceDraft.demo_number}</P_2>")
    else
      @draft.number = InvoiceDraft.demo_number if @draft.number.to_s.start_with?("FV/DEMO/")
      @draft.to_xml
    end
  end

  # The browser serializes the schema tab onto one line; indented, validator messages point at real lines.
  def indent(xml)
    Nokogiri::XML(xml, &:noblanks).to_xml(indent: 2)
  end

  def validator
    Ksef::Invoices::Validator.new(form_code: Ksef::FormCode::FA3)
  end

  # The form again: on the tab that was submitted when the builder refused the draft (`error`), and with
  # the draft's XML on the XML tabs unless a document is already there.
  def render_new(error: nil, alert: nil)
    @build_error = error
    @tab = source if error
    @xml ||= draft_xml
    flash.now[:alert] = alert || ("The form has an error — see the box next to “Send to KSeF”." if @build_error)
    render :new
  end

  # @return [String] the draft as XML — empty when the builder refuses it (the form shows why)
  def draft_xml
    @draft.to_xml
  rescue *BUILD_ERRORS => e
    @build_error ||= e
    ""
  end

  # CODE I for the invoice just sent — the seller NIP and issue date come from the XML itself.
  def qr_for(xml, label)
    doc = Nokogiri::XML(xml)
    nip = doc.at_xpath("//*[local-name()='Podmiot1']//*[local-name()='NIP']")&.text
    issued = Date.parse(doc.at_xpath("//*[local-name()='P_1']")&.text.to_s)
    link = Ksef::Qr::VerificationLink.new(qr_base_url: ksef_config.qr_url)
                                     .online(seller_nip: nip, issue_date: issued, invoice_xml: xml)
    { url: link, label: label, svg: Ksef::Qr::Code.new(link, label: label).as_svg }
  rescue StandardError
    nil
  end

  def remember(submission)
    doc = Nokogiri::XML(submission.xml)
    entry = {
      "ksef_number" => submission.ksef_number, "number" => doc.at_xpath("//*[local-name()='P_2']")&.text,
      "gross" => doc.at_xpath("//*[local-name()='P_15']")&.text, "session" => submission.session_reference,
      "invoice_reference" => submission.invoice_reference, "sent_at" => Time.current.iso8601
    }
    session[:recent_invoices] = [entry, *session[:recent_invoices]].first(8)
  end
end
