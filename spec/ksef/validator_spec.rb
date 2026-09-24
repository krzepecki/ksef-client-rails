# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Invoices::Validator do
  # Ksef::Invoices::Sample.minimal as packaged in examples/ — accepted on KSeF TEST.
  let(:valid_xml) { File.read(File.expand_path("../../examples/fa3_minimal.xml", __dir__)) }

  # Removing the mandatory `Podmiot2/JST` reproduces a real rejection case (status 450).
  let(:invalid_xml) { valid_xml.sub(%r{^\s*<JST>2</JST>\n}, "") }

  it "accepts an invoice matching the FA(3) schema" do
    expect(described_class.new.validate(valid_xml)).to be_empty
    expect(described_class.new).to be_valid(valid_xml)
  end

  it "reports a missing mandatory element (the equivalent of a 450 rejection)" do
    messages = described_class.new.validate(invalid_xml)

    expect(messages.size).to eq(1)
    expect(messages.first).to include("Podmiot2").or include("JST")
  end

  # libxml's default RECOVER mode would repair these and report them valid.
  it "reports a document that is not well-formed instead of repairing it" do
    unclosed = valid_xml.sub("</Faktura>", "")
    bare_ampersand = valid_xml.sub("<Nazwa>Seller Ltd.</Nazwa>", "<Nazwa>Seller & Co</Nazwa>")

    expect(unclosed).not_to eq(valid_xml)
    expect(bare_ampersand).not_to eq(valid_xml)
    expect(described_class.new.validate(unclosed)).to contain_exactly(/Premature end of data in tag Faktura/)
    expect(described_class.new.validate(bare_ampersand)).to contain_exactly(/xmlParseEntityRef/)
    expect(described_class.new).not_to be_valid(bare_ampersand)
  end

  it "errors names the element of each violation, telling the seller's NIP from the buyer's" do
    doc = Nokogiri::XML(valid_xml)
    doc.at_xpath("//xmlns:Podmiot2//xmlns:NIP").content = "123"
    issues = described_class.new.errors(doc.to_xml)

    expect(issues.map(&:path)).to eq(["Faktura/Podmiot2/DaneIdentyfikacyjne/NIP"])
    expect(issues.first.line).to be_a(Integer)
    expect(issues.first.message).to include("'123'")
    expect(described_class.new.errors(valid_xml.sub("</Faktura>", ""))).to contain_exactly(
      have_attributes(path: nil, message: /Premature end of data/)
    )
  end

  it "applies KSeF's XML rules beyond the schema (weryfikacja-faktury.md)" do
    validator = described_class.new
    body = valid_xml.sub(/\A<\?xml[^>]*\?>/, "")

    { "\uFEFF#{valid_xml}" => /byte order mark/,
      valid_xml.sub("encoding=\"UTF-8\"", "encoding=\"windows-1250\"") => /names encoding windows-1250/,
      "<?xml version=\"1.1\" encoding=\"UTF-8\"?>#{body}" => /XML 1.1/,
      valid_xml.sub("<Faktura", "<?xml-stylesheet href=\"s.xsl\"?>\n<Faktura") =>
        /processing instruction <\?xml-stylesheet\?>/,
      valid_xml.sub("Seller Ltd.", "Seller \u0096 Ltd.") => /U\+0096/,
      valid_xml.encode("UTF-16LE").b => /not valid UTF-8/ }.each do |xml, error|
      expect(validator.validate(xml)).to include(error), error.source
    end
  end

  it "reports a namespace error, which a strict parse alone lets through" do
    broken = valid_xml.sub("<Faktura ", "<Faktura xmlns:a=\"\" ")

    expect(described_class.new.validate(broken)).not_to be_empty
  end

  it "names the element of a violation whose prefix is declared below the root" do
    doc = Nokogiri::XML(valid_xml)
    fa = doc.at_xpath("//xmlns:Fa")
    fa.add_namespace_definition("f", fa.namespace.href)
    p2 = fa.at_xpath("xmlns:P_2")
    p2.namespace = fa.namespace_definitions.find { |ns| ns.prefix == "f" }
    p2.content = ""

    expect(described_class.new.errors(doc.to_xml).map(&:path)).to include("Faktura/Fa/P_2")
  end

  it "outline prints the form's field tree and refuses an unknown path" do
    outline = described_class.new.outline("Faktura/Fa/Adnotacje")

    expect(outline.lines.first).to match(/\AP_16\s+required\s+TWybor1_2$/)
    expect(outline).to match(/^  P_19\s+required \| choice: P_19\+P_19A\+P_19B\+P_19C\s+TWybor1$/)
    expect(described_class.new.outline.lines.map(&:split).map(&:first)).to include("Naglowek", "Podmiot1", "Fa")
    expect { described_class.new.outline("Faktura/Nope") }.to raise_error(Ksef::ConfigurationError, /Nope/)
  end

  it "outline shows the occurrence of enclosing groups, a sequence branch of a choice, and an extension's base" do
    validator = described_class.new

    expect(validator.outline("Faktura/Podmiot2/DaneIdentyfikacyjne"))
      .to match(/^KodUE\s+required \| choice: KodUE\+NrVatUE\s+TKodyKrajowUE$/)
      .and match(/^Nazwa\s+optional\s+TZnakowy512$/)
    expect(validator.outline("Faktura/Fa/Platnosc", depth: 1)).to match(/^DataZaplaty\s+optional \| choice: /)
    expect(validator.outline("Faktura/Podmiot1/AdresKoresp").lines.map { |line| line.split.first })
      .to eq(%w[KodKraju AdresL1 AdresL2 GLN])
  end

  it "outline adds each element's description from the schema on request" do
    lines = described_class.new.outline("Faktura/Fa/FaWiersz", descriptions: true).lines.map(&:rstrip)

    description = lines[lines.index { |line| line.start_with?("P_7 ") } + 1]
    expect(description).to start_with("  — Nazwa (rodzaj) towaru lub usługi")
    expect(described_class.new.outline("Faktura/Fa/FaWiersz")).not_to include("—")
  end

  it "FormCode#namespace is the targetNamespace of each packaged schema" do
    [Ksef::FormCode::FA2, Ksef::FormCode::FA3, Ksef::FormCode::FA_RR1].each do |form|
      schema = Nokogiri::XML(File.read(described_class.schema_path(form.system_code)))
      expect(form.namespace).to eq(schema.root["targetNamespace"]), form.system_code
    end
    expect(Ksef::FormCode::PEF3.namespace).to be_nil
  end

  it "the README points to the packaged examples" do
    readme = File.read(File.expand_path("../../README.md", __dir__))
    expect(readme).to include("[`examples/`](examples)")
  end

  it "parses each form's schema once per process" do
    expect(described_class.new.instance_variable_get(:@schema))
      .to be(described_class.new(form_code: "FA (3)").instance_variable_get(:@schema))
  end

  it "validate! raises SchemaValidationError with messages and the form code" do
    expect { described_class.new.validate!(invalid_xml) }
      .to raise_error(Ksef::SchemaValidationError) { |error|
        expect(error.system_code).to eq("FA (3)")
        expect(error.messages).not_to be_empty
        expect(error.errors.map(&:message)).to eq(error.messages)
        expect(error.errors.first.path).to eq("Faktura/Podmiot2/GV") # where JST was expected
        expect(error.message).to include("FA (3)")
      }
  end

  it "validate! returns true for a valid invoice" do
    expect(described_class.new.validate!(valid_xml)).to be(true)
  end

  it "accepts the form as a FormCode or as a systemCode" do
    expect(described_class.new(form_code: Ksef::FormCode::FA_RR1).system_code).to eq("FA_RR (1)")
    expect(described_class.new(form_code: "FA (2)").system_code).to eq("FA (2)")
  end

  it "refuses a form with no packaged schema (PEF/UBL)" do
    expect { described_class.new(form_code: Ksef::FormCode::PEF3) }
      .to raise_error(Ksef::ConfigurationError, /PEF \(3\)/)
  end

  it "ships the schemas with the gem and resolves the base type import" do
    expect(File).to exist(described_class.schema_path("FA (3)"))
    expect(File).to exist(File.join(described_class::SCHEMA_ROOT, "bazowe/StrukturyDanych_v10-0E.xsd"))
  end
end
