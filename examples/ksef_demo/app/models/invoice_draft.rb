# frozen_string_literal: true

require "date"
require "ksef"

# The invoice form: the gem's `Ksef::Invoices::Builder` plus the form's labels, its "Typical" / "Full"
# tabs and parsing of the submitted params.
class InvoiceDraft < Ksef::Invoices::Builder
  # Rate (the `P_12` value) → the gem's summary fields plus a label; `full:` rates show on the Full tab.
  RATES = {
    "23" => { net: "P_13_1", vat: "P_14_1", percent: 23, label: "23%" },
    "8" => { net: "P_13_2", vat: "P_14_2", percent: 8, label: "8%" },
    "5" => { net: "P_13_3", vat: "P_14_3", percent: 5, label: "5%" },
    "0 KR" => { net: "P_13_6_1", percent: 0, label: "0% (domestic)" },
    "0 WDT" => { net: "P_13_6_2", percent: 0, label: "0% (intra-EU supply)", full: true },
    "0 EX" => { net: "P_13_6_3", percent: 0, label: "0% (export)", full: true },
    "zw" => { net: "P_13_7", percent: 0, label: "exempt" },
    "np I" => { net: "P_13_8", percent: 0, label: "np I (outside Poland)", full: true },
    "np II" => { net: "P_13_9", percent: 0, label: "np II (art. 100 services)", full: true },
    "oo" => { net: "P_13_10", percent: 0, label: "oo (reverse charge)", full: true }
  }.freeze

  # `FormaPlatnosci` codes from the schema, with labels.
  PAYMENT_METHODS = {
    "6" => "Bank transfer", "1" => "Cash", "2" => "Card", "5" => "Credit",
    "7" => "Mobile", "3" => "Voucher", "4" => "Cheque"
  }.freeze

  # `Adnotacje` flags (1 = yes, 2 = no) offered on the Full tab.
  ANNOTATIONS = {
    "cash_method" => ["P_16", "Cash accounting (metoda kasowa)"],
    "self_billing" => ["P_17", "Self-billing (samofakturowanie)"],
    "reverse_charge" => ["P_18", "Reverse charge (odwrotne obciążenie)"],
    "split_payment" => ["P_18A", "Split payment (mechanizm podzielonej płatności)"],
    "triangular" => ["P_23", "Simplified triangular procedure (procedura trójstronna)"]
  }.freeze

  INVOICE_TYPES = { "VAT" => "Standard VAT invoice", "KOR" => "Correction (KOR)" }.freeze
  CORRECTION_TYPES = { "" => "— not stated —", "1" => "1 — effect in the original invoice's period",
                       "2" => "2 — effect in the correction's period", "3" => "3 — other period" }.freeze

  # The numbers the builder reads (`Ksef::Invoices::Builder::Number`) as HTML `pattern`s, which browsers
  # compile with the `v` flag: "1234,56", "1 234,56" (space or no-break space groups), a sign; price and
  # discount at most 2 decimal places, quantity 6 (trailing zeros aside).
  INTEGER_PART = '\s*[+\-]?(?:\d+|\d{1,3}(?:[ \u00A0\u202F]\d{3})+)'
  PRICE_PATTERN = "#{INTEGER_PART}(?:[.,]\\d{1,2}0*)?\\s*".freeze
  QUANTITY_PATTERN = "#{INTEGER_PART}(?:[.,]\\d{1,6}0*)?\\s*".freeze
  # A NIP as `Ksef::Nip` reads it: 10 digits, with spaces, hyphens and a "PL" prefix allowed.
  NIP_PATTERN = '\s*(?:[Pp][Ll])?[\s\-]*(?:\d[\s\-]*){10}'

  # Buyer (`Podmiot2`) identification: NIP, EU VAT number, another identifier, or none.
  BUYER_ID_TYPES = { "nip" => "Polish NIP", "eu" => "EU VAT number", "other" => "Other tax ID",
                     "none" => "No identifier (consumer)" }.freeze

  # The demo's default invoice: `Ksef::Invoices::Sample.minimal` — exactly the document confirmed on live
  # TEST; `full: true` is `Sample.typical` (sale date, place, a bank transfer).
  # @param seller_nip [String] must match the KSeF session context
  # @return [InvoiceDraft]
  def self.sample(seller_nip:, invoice_number: nil, now: Time.now, full: false)
    level = full ? :typical : :minimal
    sample = Ksef::Invoices::Sample.public_send(level, seller_nip: seller_nip,
                                                       invoice_number: invoice_number || demo_number(now),
                                                       issue_date: Ksef::PolishTime.today(now))
    new(**sample.to_h.except(:system_info))
  end

  # Builds a draft from form params (string keys; `lines` as an array or an index-keyed hash).
  # @return [InvoiceDraft]
  def self.from_params(params, seller_nip:)
    p = params.to_h.transform_keys(&:to_s)
    text = p.slice(*%w[number place payment_method bank_account bank_name paid exemption_reason invoice_type
                       correction_reason correction_type corrected_number corrected_ksef_number footer krs
                       regon bdo]).transform_keys(&:to_sym)
    dates = %w[issue_date sale_date due_date paid_date corrected_date].to_h { |k| [k.to_sym, date(p[k])] }
    new(
      **text, **dates,
      currency: p["currency"].to_s.strip.empty? ? "PLN" : p["currency"],
      seller: party(p["seller"].to_h.merge("nip" => seller_nip)), buyer: party(p["buyer"].to_h),
      lines: line_params(p["lines"]).map { |l| l.to_h.transform_keys(&:to_sym).slice(*LINE_FIELDS) },
      annotations: p["annotations"].to_h.select { |_, v| v.to_s == "1" }.keys.map(&:to_s)
    )
  end

  def self.demo_number(now = Time.now)
    "FV/DEMO/#{now.strftime('%Y%m%d-%H%M%S')}"
  end

  # A blank country stays blank: the builder reads it as PL for a NIP or consumer buyer and refuses it
  # for an EU or other tax ID.
  def self.party(hash)
    attrs = hash.to_h.transform_keys(&:to_sym).slice(*PARTY_FIELDS)
    country = attrs[:country].to_s.strip.upcase
    attrs[:country] = country.empty? ? nil : country
    Ksef::Invoices::Builder::Party.new(**attrs)
  end

  # The "YYYY-MM-DD" of a date field as given — the builder refuses anything else.
  def self.date(value)
    value.to_s.strip.empty? ? nil : value.to_s.strip
  end

  def self.line_params(value)
    lines = value.is_a?(Hash) ? value.sort_by { |k, _| k.to_i }.map(&:last) : Array(value)
    named = lines.map(&:to_h).reject { |l| l["name"].to_s.strip.empty? }
    named.map { |l| RATES.key?(l["rate"].to_s) ? l : l.merge("rate" => "23") }
  end

  private_class_method :party, :date, :line_params

  def initialize(**attrs)
    super(system_info: "ksef-ruby-demo", **attrs)
  end
end
