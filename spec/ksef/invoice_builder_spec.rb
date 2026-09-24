# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Invoices::Builder do
  let(:validator) { Ksef::Invoices::Validator.new }
  let(:created_at) { Time.utc(2026, 10, 12, 10) }
  let(:base) do
    { number: "FV/1", issue_date: Date.new(2026, 10, 12),
      seller: { nip: "5555555555", name: "Seller", address: "Warsaw" },
      buyer: { nip: "1111111111", name: "Buyer", address: "Cracow" },
      lines: [{ name: "Service", unit: "szt.", quantity: "2", unit_price: "100.00", rate: "23" }] }
  end

  def build(**overrides)
    described_class.new(**base, **overrides)
  end

  def xml_of(invoice)
    Nokogiri::XML(invoice.to_xml(created_at: created_at)).tap(&:remove_namespaces!)
  end

  # Every variant the builder can emit must match the FA(3) schema.
  matrix = {
    "a buyer with an EU VAT number" => { buyer: { name: "EU GmbH", address: "Berlin", country: "DE", id_type: "eu",
                                                  eu_code: "de", vat_eu: "123456789" } },
    "a buyer with another tax ID" => { buyer: { name: "US Inc.", address: "NYC", country: "US", id_type: :other,
                                                id_number: "98-765" } },
    "a consumer without an identifier" => { buyer: { name: "Jan Kowalski", address: "Cracow", id_type: "none" } },
    "contact data" => { seller: { nip: "5555555555", name: "S", address: "A", email: "a@b.pl", phone: "+48 1" } },
    "a correction of a KSeF invoice" => { invoice_type: "KOR", correction_reason: "Price", correction_type: "2",
                                          corrected_date: Date.new(2026, 10, 7), corrected_number: "FV/0",
                                          corrected_ksef_number: "5555555555-20261007-0100001AF629-72" },
    "a correction of an invoice issued outside KSeF" => { invoice_type: "KOR", corrected_date: "2026-10-07",
                                                          corrected_number: "FV/0" },
    "a paid invoice" => { payment_method: :cash, paid: true, paid_date: Date.new(2026, 10, 12) },
    "a bank transfer" => { payment_method: "6", due_date: Date.new(2026, 10, 26),
                           bank_account: "17 1000 0000 0000 0000 0000 0001", bank_name: "Bank" },
    "every annotation" => { annotations: described_class::ANNOTATIONS.keys },
    "line details and a discount" => { lines: [{ name: "X", unit: "szt.", quantity: "1,5", unit_price: "10,50",
                                                 rate: "8", index: "I", gtin: "5901234123457", pkwiu: "62.01",
                                                 cn: "8471", gtu: "GTU_12", discount: "1.00" }] },
    "a footer and registers" => { footer: "Thanks", krs: "0000123456", regon: "123456785", bdo: "000012345" },
    "the place and the sale date" => { place: "Gdansk", sale_date: Date.new(2026, 10, 11) },
    "a payment made" => { paid: "true", paid_date: "2026-10-12" },
    "a due date without a payment method" => { due_date: Date.new(2026, 10, 26) },
    "a foreign-currency invoice without VAT" => {
      currency: "EUR", lines: [{ name: "S", quantity: "1", unit_price: "10", rate: "np II" }],
      buyer: { name: "EU GmbH", address: "Berlin", country: "DE", id_type: "eu", eu_code: "DE", vat_eu: "123456789" }
    },
    "every rate on one invoice" => { exemption_reason: "art. 113 ust. 1 ustawy o VAT",
                                     lines: described_class::RATES.keys.map do |rate|
                                       { name: "Rate #{rate}", quantity: "1", unit_price: "10.00", rate: rate }
                                     end }
  }
  matrix.each do |label, overrides|
    it "renders #{label} valid against FA(3)" do
      expect(validator.validate(build(**overrides).to_xml(created_at: created_at))).to eq([])
    end
  end

  it "sums net and VAT per rate into the summary fields" do
    invoice = build(lines: [{ name: "A", quantity: "2", unit_price: "100", rate: "23" },
                            { name: "B", quantity: "1", unit_price: "50", rate: "8" },
                            { name: "C", quantity: "1", unit_price: "30", rate: "zw" }],
                    exemption_reason: "art. 113 ust. 1 ustawy o VAT")
    fa = xml_of(invoice).at_xpath("//Fa")

    expect(%w[P_13_1 P_14_1 P_13_2 P_14_2 P_13_7 P_15].map { |name| fa.at_xpath(name).text })
      .to eq(%w[200.00 46.00 50.00 4.00 30.00 330.00])
    expect(fa.at_xpath("Adnotacje/Zwolnienie/P_19A").text).to eq("art. 113 ust. 1 ustawy o VAT")
  end

  describe "numbers" do
    def line_fields(**line)
      fa = xml_of(build(lines: [{ name: "X", rate: "23" }.merge(line)])).at_xpath("//Fa")
      %w[P_8B P_9A P_10 P_11].to_h { |name| [name, fa.at_xpath("FaWiersz/#{name}")&.text] }
    end

    it "reads Polish formats, Integers, BigDecimals and Floats exactly" do
      expect(line_fields(quantity: "1 000", unit_price: "1 234,56"))
        .to include("P_8B" => "1000", "P_9A" => "1234.56", "P_11" => "1234560.00")
      expect(line_fields(quantity: "2", unit_price: "1\u00A0234,50", discount: "0,5"))
        .to include("P_9A" => "1234.50", "P_10" => "0.50", "P_11" => "2468.50")
      expect(line_fields(quantity: 3, unit_price: BigDecimal("0.10")))
        .to include("P_8B" => "3", "P_9A" => "0.10", "P_11" => "0.30")
      expect(line_fields(quantity: 1.5, unit_price: 10.5)).to include("P_8B" => "1.5", "P_11" => "15.75")
      expect(line_fields(quantity: "0,333333", unit_price: "3")).to include("P_8B" => "0.333333", "P_11" => "1.00")
    end

    it "refuses a missing or malformed number instead of writing 0" do
      { { unit_price: "1.234,56" } => /line 1: unit_price is not a decimal number/,
        { unit_price: "100 zł" } => /unit_price is not a decimal number/,
        { unit_price: nil } => /line 1: unit_price is required/,
        { unit_price: "" } => /unit_price is required/,
        { quantity: "abc" } => /quantity is not a decimal number/,
        { quantity: Rational(1, 3) } => /quantity is not a decimal number/,
        { quantity: Float::NAN } => /quantity is not a decimal number/,
        { discount: "ten" } => /discount is not a decimal number/ }.each do |line, error|
        expect { line_fields(quantity: "1", unit_price: "100", **line) }
          .to raise_error(Ksef::ConfigurationError, error)
      end
    end

    it "refuses prices and discounts with more than 2 decimal places, quantities with more than 6" do
      expect { line_fields(quantity: "1000", unit_price: "0.125") }
        .to raise_error(Ksef::ConfigurationError, /unit_price has more than 2 decimal places/)
      expect { line_fields(quantity: "1", unit_price: "1", discount: "0.005") }
        .to raise_error(Ksef::ConfigurationError, /discount has more than 2 decimal places/)
      expect { line_fields(quantity: "1.1234567", unit_price: "1") }
        .to raise_error(Ksef::ConfigurationError, /quantity has more than 6 decimal places/)
      expect(line_fields(quantity: "1", unit_price: "100.000")).to include("P_9A" => "100.00")
    end

    it "rounds half up whatever the thread's BigDecimal rounding mode" do
      BigDecimal.save_rounding_mode do
        BigDecimal.mode(BigDecimal::ROUND_MODE, :banker)
        invoice = build(lines: [{ name: "X", quantity: "0.5", unit_price: "0.25", rate: "23" }])
        fa = xml_of(invoice).at_xpath("//Fa")

        expect([fa.at_xpath("FaWiersz/P_11").text, fa.at_xpath("P_14_1").text]).to eq(%w[0.13 0.03])
      end
    end

    it "writes negative difference rows of a correction" do
      invoice = build(invoice_type: "KOR", corrected_date: "2026-10-07", corrected_number: "FV/0",
                      lines: [{ name: "X", quantity: "2", unit_price: "-10.00", rate: "23" }])
      fa = xml_of(invoice).at_xpath("//Fa")

      expect(%w[FaWiersz/P_9A FaWiersz/P_11 P_13_1 P_14_1 P_15].map { |name| fa.at_xpath(name).text })
        .to eq(%w[-10.00 -20.00 -20.00 -4.60 -24.60])
    end
  end

  describe "tax annotations" do
    it "marks reverse charge for an oo or np II line" do
      ["oo", "np II"].each do |rate|
        invoice = build(lines: [{ name: "X", quantity: "1", unit_price: "10", rate: rate }])

        expect(xml_of(invoice).at_xpath("//Adnotacje/P_18").text).to eq("1")
      end
      expect(xml_of(build).at_xpath("//Adnotacje/P_18").text).to eq("2")
    end

    it "requires the exemption basis for a zw line" do
      invoice = build(lines: [{ name: "X", quantity: "1", unit_price: "10", rate: "zw" }])

      expect { invoice.to_xml }.to raise_error(Ksef::ConfigurationError, /exemption_reason is required/)
    end

    it "refuses a foreign-currency invoice with VAT, which would need the VAT in PLN" do
      expect { build(currency: "EUR").to_xml }.to raise_error(Ksef::ConfigurationError, /P_14_xW/)
    end
  end

  describe "payment" do
    def payment(**fields)
      xml_of(build(**fields)).at_xpath("//Platnosc")
    end

    it "keeps the due date, the account and the payment made without a payment method" do
      node = payment(due_date: "2026-10-26", bank_account: "17 1000 0000 0000 0000 0000 0001")

      expect(node.element_children.map(&:name)).to eq(%w[TerminPlatnosci RachunekBankowy])
      expect(payment(paid: true, paid_date: "2026-10-12").element_children.map(&:name))
        .to eq(%w[Zaplacono DataZaplaty])
      expect(payment).to be_nil
    end

    it "refuses a paid flag without its date, a date without the flag, and an unknown flag" do
      expect { build(paid: true).to_xml }.to raise_error(Ksef::ConfigurationError, /paid_date is required/)
      expect { build(paid_date: "2026-10-12").to_xml }.to raise_error(Ksef::ConfigurationError, /paid is not true/)
      expect { build(paid: "yes", paid_date: "2026-10-12").to_xml }
        .to raise_error(Ksef::ConfigurationError, /paid must be true or false/)
      expect { build(bank_name: "Bank").to_xml }.to raise_error(Ksef::ConfigurationError, /bank_account/)
    end
  end

  it "leaves the caller's created_at as it was" do
    created = Time.new(2026, 10, 12, 12, 0, 0, "+02:00").freeze
    doc = Nokogiri::XML(build.to_xml(created_at: created)).tap(&:remove_namespaces!)

    expect(doc.at_xpath("//DataWytworzeniaFa").text).to eq("2026-10-12T10:00:00Z")
    expect(created.utc_offset).to eq(7200)
  end

  it "requires the country of a buyer identified by an EU VAT number or another tax ID" do
    expect { build(buyer: { name: "B", address: "Berlin", id_type: "eu", eu_code: "DE", vat_eu: "1" }).to_xml }
      .to raise_error(Ksef::ConfigurationError, /buyer country is required/)
    expect { build(buyer: { name: "B", address: "NYC", id_type: "other", id_number: "1" }).to_xml }
      .to raise_error(Ksef::ConfigurationError, /buyer country is required/)
  end

  it "refuses missing required values and malformed codes" do
    { { issue_date: nil } => /issue_date required/,
      { number: " " } => /number required/,
      { buyer: { nip: "1111111111", name: "B" } } => /buyer address required/,
      { invoice_type: "KOR" } => /corrected_date, corrected_number required/,
      { currency: "eur" } => /Unknown currency: eur/,
      { buyer: { nip: "1111111111", name: "B", address: "A", country: "pl" } } => /Unknown country/,
      { lines: [{ name: "X", quantity: "1", unit_price: "1", rate: "23", gtu: "GTU_14" }] } =>
        /line 1: Unknown GTU code/,
      { lines: [{ name: "X", quantity: "1", unit_price: "1", rate: "23", colour: "red" }] } =>
        /Unknown line field\(s\): colour/ }.each do |overrides, error|
      expect { build(**overrides).to_xml }.to raise_error(Ksef::ConfigurationError, error)
    end
  end

  it "refuses text that is not UTF-8 or holds a character KSeF refuses" do
    expect { build(lines: [{ name: "Dostawa \u0096 serwis", quantity: "1", unit_price: "1", rate: "23" }]).to_xml }
      .to raise_error(Ksef::ConfigurationError, /line 1 name contains U\+0096/)
    expect { build(footer: "A\u0001B").to_xml }.to raise_error(Ksef::ConfigurationError, /footer contains U\+0001/)
    expect { build(place: "Zażółć".encode("Windows-1250")).to_xml }
      .to raise_error(Ksef::ConfigurationError, /place is not a UTF-8 String/)
  end

  it "raises SchemaValidationError for output the schema still refuses" do
    expect { build(seller: { nip: "5555555555", name: "S" * 600, address: "A" }).to_xml }
      .to raise_error(Ksef::SchemaValidationError, /Nazwa/)
  end

  it "normalizes the NIPs and writes the form header from FormCode::FA3" do
    doc = xml_of(build(seller: { nip: "PL 555-555-55-55", name: "S", address: "A" }))

    expect(doc.at_xpath("//Podmiot1//NIP").text).to eq("5555555555")
    expect(doc.at_xpath("//KodFormularza").attributes.transform_values(&:value))
      .to eq("kodSystemowy" => "FA (3)", "wersjaSchemy" => "1-0E")
    expect(doc.at_xpath("//SystemInfo").text).to eq("ksef-client-rails")
  end

  it "refuses unknown codes, an invalid NIP and a Time where a date belongs" do
    expect { build(lines: [{ name: "X", quantity: "1", unit_price: "1", rate: "7" }]).to_xml }
      .to raise_error(Ksef::ConfigurationError, /Unknown VAT rate/)
    expect { build(payment_method: :barter).to_xml }.to raise_error(Ksef::ConfigurationError, /payment_method/)
    expect { build(annotations: [:vip]).to_xml }.to raise_error(Ksef::ConfigurationError, /annotation/)
    expect { build(buyer: { name: "B", address: "A", id_type: "pesel" }).to_xml }
      .to raise_error(Ksef::ConfigurationError, /id_type/)
    expect { build(seller: { nip: "1234567890", name: "S", address: "A" }).to_xml }
      .to raise_error(Ksef::ConfigurationError, /seller NIP/)
    expect { build(issue_date: Time.utc(2026, 10, 12, 23)).to_xml }
      .to raise_error(Ksef::ConfigurationError, /issue_date must be a Date/)
    expect { build(issue_date: "2026-10-12T22:00:00.000Z").to_xml }
      .to raise_error(Ksef::ConfigurationError, /issue_date is not a valid date/)
    expect { build(colour: "red") }.to raise_error(Ksef::ConfigurationError, /colour/)
  end
end

RSpec.describe Ksef::Invoices::Sample do
  it "dates an invoice with the calendar day in Poland by default" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 12, 22, 30))

    expect(described_class.minimal(seller_nip: "5555555555", invoice_number: "1").issue_date)
      .to eq(Date.new(2026, 10, 13))
  end

  %i[minimal typical full].each do |level|
    it "examples/fa3_#{level}.xml is what Sample.#{level} renders, and it is valid" do
      path = File.expand_path("../../examples/fa3_#{level}.xml", __dir__)
      file = File.read(path)
      doc = Nokogiri::XML(file).tap(&:remove_namespaces!)
      invoice = described_class.public_send(level, seller_nip: doc.at_xpath("//Podmiot1//NIP").text,
                                                   invoice_number: doc.at_xpath("//P_2").text,
                                                   issue_date: Date.iso8601(doc.at_xpath("//P_1").text))

      expect(invoice.to_xml(created_at: Time.iso8601(doc.at_xpath("//DataWytworzeniaFa").text))).to eq(file),
                                                                                                    "rake xsd:examples"
      expect(Ksef::Invoices::Validator.new.validate(file)).to eq([])
    end
  end
end
