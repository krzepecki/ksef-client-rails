# Invoice XML

KSeF takes invoices as XML in the **FA(3)** format, the official schema for structured invoices. You
can write that XML yourself, or build it in Ruby with `Ksef::Invoices::Builder`. Either way, check it
with `Ksef::Invoices::Validator` before you send it.

## Build an invoice

```ruby
today = Ksef::PolishTime.today                     # P_1 is the calendar day in Poland
invoice = Ksef::Invoices::Builder.new(
  number: "FV/2026/10/1", issue_date: today,
  seller: { nip: nip, name: "Seller Ltd.", address: "1 Test Street, 00-001 Warsaw" },
  buyer: { nip: "1111111111", name: "Buyer Inc.", address: "2 Example Street, 00-002 Warsaw" },
  lines: [{ name: "Service", unit: "szt.", quantity: "1", unit_price: "100.00", rate: "23" }],
  payment_method: :transfer, due_date: today + 14, bank_account: "17100000000000000000000001"
)
invoice_xml = invoice.to_xml
```

The builder covers parties, lines with any of the ten VAT rates, payment, annotations, corrections
and the footer. It computes the totals for you.

**Dates.** `issue_date` (the `P_1` field) is the calendar day in Poland:

- Use `Ksef::PolishTime.today`. On a UTC server, `Date.today` is still the day before for the first
  hour or two after midnight in Poland.
- KSeF refuses a date later than the day it receives the invoice. An earlier date marks the invoice
  as issued offline.

**Amounts.** Integers, BigDecimals or strings with a comma or a dot — `"1 234,56"` works too.
Prices and discounts take at most 2 decimal places, quantities at most 6.

**Done for you.** A line with rate `oo` or `np II` turns on the reverse-charge annotation (`P_18`).

**Required.** A buyer identified by an EU VAT number or another tax ID needs `country`.

### What the builder refuses

It never guesses a value. It raises `Ksef::ConfigurationError` (naming the line, for amounts) for:

- an amount in any other form;
- an unknown code, a missing required value, or text KSeF refuses;
- a foreign currency with a 23%, 8% or 5% line (the VAT would also have to be stated in PLN);
- a `zw` (exempt) line without `exemption_reason` (the legal basis, `P_19A`).

`to_xml` also checks its own output against the schema: a value that is too long, for example,
raises `Ksef::SchemaValidationError`.

### Corrections

Pass `invoice_type: "KOR"` with `corrected_date:` and `corrected_number:`. A correction carries only
the change — its totals are summed from its lines — so give either:

- difference lines: quantity `"2"` at `"-10.00"` for a 20.00 reduction; or
- the original line negated, plus the corrected line.

## Sample invoices

Three ready-made invoices, each accepted on KSeF TEST. Their XML ships with the gem in
[`examples/`](../examples).

| Sample | What's in it |
|---|---|
| `Ksef::Invoices::Sample.minimal` | one 23% line — the fields every invoice needs |
| `Ksef::Invoices::Sample.typical` | minimal plus the sale date, the place of issue and a bank transfer due in 14 days |
| `Ksef::Invoices::Sample.full` | most fields the builder supports, with five of the ten rates |

They take `seller_nip:`, `invoice_number:` and `issue_date:` (today in Poland by default) and return
a builder. The full one has no payment already made, no buyer identified other than by NIP, no
correction and no annotations.

## Fields the builder doesn't cover

Start from the XML. To see every field of a form, with its description from the schema:

```ruby
puts Ksef::Invoices::Validator.new.outline("Faktura/Fa/FaWiersz", descriptions: true)
```

The Ministry's SDKs have more templates (attachments, `Podmiot3`, FA_RR, PEF):
[C#](https://github.com/CIRFMF/ksef-client-csharp/tree/main/KSeF.Client.Tests.Core/Templates),
[Java](https://github.com/CIRFMF/ksef-client-java/tree/main/demo-web-app/src/integrationTest/resources/xml/invoices/sample).

## Check an invoice before sending

```ruby
validator = Ksef::Invoices::Validator.new   # FA(3); or form_code: Ksef::FormCode::FA_RR1 / FA2
validator.validate(xml)    # => ["...Podmiot2: Missing child element(s)..."], [] when valid
validator.errors(xml)      # => [#<Issue path="Faktura/Podmiot2/DaneIdentyfikacyjne/NIP", line=21, message="...">]
validator.validate!(xml)   # raises Ksef::SchemaValidationError (#messages, #errors)
```

- `errors` says which element is wrong, e.g. to show the message next to a form field.
- It works offline: the FA(2), FA(3) and FA_RR(1) schemas ship with the gem. PEF is not supported.
- Besides the schema, it checks KSeF's XML rules: UTF-8 without a BOM, no other declared encoding,
  XML 1.0, no processing instructions, none of the characters KSeF refuses (C1 controls, Unicode
  noncharacters).
- Broken XML is reported, never repaired.
- What fails here fails in KSeF too. The messages come from libxml2, not from KSeF.

### What only KSeF can check

- `KodFormularza` must match the session's form code.
- The context must be allowed to invoice for the `Podmiot1` NIP. Usually it is that NIP; with
  self-billing or a tax representative, it is the other party's.
- The seller NIP, invoice type and number (`P_2`) must not repeat an earlier invoice.
- `P_1` must not be later than the day KSeF receives the invoice.
- On PROD, every NIP must have a valid check digit.
