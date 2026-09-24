# ksef — Ruby/Rails client for KSeF API 2.0

Pure-Ruby client for the Polish National e-Invoice System
([KSeF API 2.0](https://github.com/CIRFMF/ksef-api)), covering every operation of the **API 2.8.1**
contract: resources mapped 1:1 to the endpoints, plus high-level flows — XAdES and token
authentication, interactive and batch sessions, export, incremental sync, QR codes. Works in plain
Ruby; the Rails integration loads only under Rails.

> **Status:** every request is checked against the API 2.8.1 OpenAPI document on each test run, and
> every flow passes on live KSeF TEST ([Verification](#verification)). Not exercised live: 5xx retries,
> `SessionUnavailable` and a token refresh refused with 401.

## Installation

```ruby
gem "ksef-client-rails", "~> 1.0"
gem "rqrcode"                       # optional: QR rendering
gem "minitar"                       # optional: tar.gz packages
```

In Rails, `bin/rails g ksef:install` creates `config/initializers/ksef.rb`.

## Quick start

On TEST: sign in, fetch your invoices, issue one. The same code runs on DEMO and PROD (where invoices
are legally binding).

```ruby
require "ksef"

Ksef.configure { |c| c.environment = :test }   # :test | :demo | :prod
client = Ksef::Client.new
nip = "5555555555"                             # the company you act for (the context)
```

**1. Sign in** — with a KSeF token (generated in the taxpayer app) or with a certificate / company seal:

```ruby
auth = Ksef::Auth::Coordinator.new(client)

# a) KSeF token
result = auth.authenticate_with_token(context: { nip: nip }, token: ENV.fetch("KSEF_TOKEN"))

# b) certificate (XAdES signature) — PEM/DER files, or PKCS#12: OpenSSL::PKCS12.new(File.binread("seal.p12"), password)
cert = OpenSSL::X509::Certificate.new(File.binread("ksef.cert"))
key  = OpenSSL::PKey.read(File.binread("ksef.key"), ENV.fetch("KSEF_CERT_PASSWORD", ""))
result = auth.authenticate(context: { nip: nip }, signer: Ksef::Xades::Signer.new(cert: cert, key: key))

client = client.with_access_token(result.access_token)   # valid 15 min — see Refreshing the access token
```

**2. Fetch invoices** — received (you are the buyer, `Subject2`) or issued (`Subject1`):

```ruby
filters = { "subjectType" => "Subject2",
            "dateRange" => { "dateType" => "Invoicing", "from" => (Time.now - (30 * 86_400)).utc.iso8601 } }
client.invoices.query_metadata(filters: filters, sort_order: "Desc").first(10).each do |meta|
  puts "#{meta['invoiceNumber']} from #{meta.dig('seller', 'nip')}: #{meta['grossAmount']} #{meta['currency']}"
  File.write("#{meta['ksefNumber']}.xml", client.invoices.get_by_ksef_number(meta["ksefNumber"]))
end
```

**3. Issue an invoice** — FA(3) XML, from a file or built with [`Ksef::Invoices::Builder`](#invoice-xml),
with the context's NIP (or one it may invoice for) in `Podmiot1`:

```ruby
invoice_xml = Ksef::Invoices::Sample.minimal(seller_nip: nip, invoice_number: "FV/2026/10/1").to_xml   # or File.read
Ksef::Invoices::Validator.new.validate!(invoice_xml)   # the XSD and KSeF's XML rules, checked locally
session = Ksef::Sessions::Online.open(client)
sent = session.send_invoice(invoice_xml)               # encrypted and hashed by the gem
session.close
upo = session.wait_for_upo(sent.reference_number)      # waits until accepted; the UPO XML
ksef_number = client.sessions.invoice(session.reference_number, sent.reference_number)["ksefNumber"]

link = Ksef::Qr::VerificationLink.from_client(client).online(seller_nip: nip, invoice_xml: invoice_xml)
File.write("qr.svg", Ksef::Qr::Code.new(link, label: ksef_number).as_svg)   # the code printed on the invoice (rqrcode)
```

A rejected invoice raises `Ksef::InvoiceRejected` from `wait_for_upo` ([Interactive session](#interactive-session)).
For many invoices, use a [batch session](#batch-session), an [export or the incremental sync](#download-metadata-and-export).

## Configuration

```ruby
Ksef.configure do |c|
  c.environment = :demo
  c.timeout = 30
  c.logger = Logger.new($stdout)
end
```

| Option | Default | Meaning |
|---|---|---|
| `environment` | `:test` | `:test`, `:demo`, `:prod` |
| `timeout` / `open_timeout` | `60` / `15` | seconds |
| `max_retries` | `2` | a 429 is retried for any call; 500/502/503/504 and connection failures (not TLS) only for idempotent ones (GET, presigned transfers), with backoff; a failure before anything was sent (a connect timeout, a busy connection pool) for any call |
| `max_retry_after` | `60` | longest `Retry-After` slept through; a longer one raises `Ksef::RateLimited`; `nil` — no limit |
| `adapter` | `:net_http_persistent` (keep-alive) | Faraday adapter, e.g. `[:net_http_persistent, { pool_size: 5 }]` — at least the number of threads sharing a client, as a thread waits 0.5 s for a free connection; `:net_http` turns keep-alive off |
| `proxy` | `ENV["KSEF_PROXY"]` | HTTP proxy |
| `logger` | `nil` (Rails: `Rails.logger`) | every request at `debug` (method, path, status, time), retries, `X-System-Warning`, polling — never secrets |
| `ksef_features` | `[]` | `X-KSeF-Feature` flags, e.g. `subject-identifier-validation` |
| `default_headers`, `prefer_problem_details`, `user_agent`, `api_base_url_override`, `qr_base_url_override` | | extra headers, error format, mock hosts |

- Per client: `Ksef::Client.new(config: Ksef.config.with(environment: :demo))` — a copy that keeps the
  other options (in Rails, what `config.ksef.*` and the initializer set); `Ksef::Configuration.new`
  starts from the defaults. Configure before building clients: a client copies the configuration it is
  built with. A value of the wrong type (`timeout: "60"`) raises `Ksef::ConfigurationError` when set.
- Rails: `config.ksef.<option>` takes the same keys (an unknown key stops the boot). The generated
  initializer runs after it and sets only the environment, from `KSEF_ENV` when present — never
  derive the environment from `Rails.env`, staging often runs as production.
- A proxy password with percent-encoded characters needs `adapter: :net_http` — the keep-alive adapter
  (faraday-net_http_persistent 2.3) fails on it with `URI::InvalidComponentError`.
- Keep one client per environment and process — it holds the keep-alive connection, the Ministry key
  cache and the CA store, and is thread-safe — and derive per-context clients with
  `client.with_access_token(token)` rather than assigning `client.access_token =` on a shared one.
  `client.close` closes its keep-alive connections; the next request opens new ones.
- Build clients after a `fork`. A client used both before and after one shares its keep-alive
  connection with the other process, so its next request, GET or POST, can fail with
  `Ksef::NetworkError` for about 5 s (a POST may or may not have been processed); a client kept across a
  fork needs `adapter: :net_http`.
- Each HTTP attempt is published as `request.ksef` (ActiveSupport::Notifications: `method`, `path`, `status`).
- Tokens and keys are redacted in `#inspect` and `pp`; presigned transfers refuse non-`https` URLs.
- `enforce_xades_compliance!` is not needed: KSeF validates XAdES strictly on every environment.

## Authentication

### XAdES signature

```ruby
cert = OpenSSL::X509::Certificate.new(File.binread("ksef.cert"))   # PEM or DER
key  = OpenSSL::PKey.read(File.binread("ksef.key"), ENV.fetch("KSEF_CERT_PASSWORD", ""))
# or from PKCS#12: p12 = OpenSSL::PKCS12.new(File.binread("seal.p12"), password); cert, key = p12.certificate, p12.key

result = Ksef::Auth::Coordinator.new(client).authenticate(
  context: { nip: "5555555555" },                            # or internal_id:, nip_vat_ue:, peppol_id:
  signer: Ksef::Xades::Signer.new(cert: cert, key: key),     # RSA or EC P-256
  subject_identifier_type: :certificate_subject,             # or :certificate_fingerprint
  verify_certificate_chain: false,                           # true adds an OCSP/CRL check
  allowed_ips: { addresses: ["203.0.113.7"] }                # optional; also ranges:, masks:
)
result.access_token # and result.refresh_token
```

- Pass `""` when there is no password, never `nil`: if the key turns out to be encrypted, `nil` makes
  OpenSSL prompt on the terminal. A key that does not match the certificate, or one KSeF refuses (RSA
  under 2048 bits, EC under 256), raises `Ksef::CryptoError` up front instead of KSeF's opaque `9105`.
- `:certificate_subject` needs `organizationIdentifier` `VATPL-<NIP>` (a seal) or `serialNumber`
  `TINPL-<NIP>`/`PNOPL-<PESEL>` (a person); other certificates use `:certificate_fingerprint` once
  permissions are granted to the fingerprint. Self-signed certificates work on TEST only.
- Any object responding to `#call(xml)` or `#sign(xml)` can replace the signer (HSM, qualified
  signature): `signer: ->(xml) { MyHsm.sign_xades(xml) }`. It must return the signed XML; a key alone
  (`OpenSSL::PKey`) is refused — wrap it in `Ksef::Xades::Signer`.
- A NIP context (and `seller_nip:` of the QR links) may carry spaces, dashes or a `PL` prefix: it is
  sent as its 10 digits. An invalid context, subject type or `allowed_ips` (at most 10 of each kind)
  raises `Ksef::ConfigurationError` before any request.

### Trying TEST without credentials

TEST accepts a self-signed seal (`organizationIdentifier` `VATPL-<NIP>`) as the owner of any valid NIP:

```ruby
nip = loop do                                    # a random NIP with a valid check digit
  digits = [rand(1..9), *Array.new(8) { rand(10) }]
  check = Ksef::Nip::WEIGHTS.each_with_index.sum { |weight, i| weight * digits[i] } % 11
  candidate = (digits + [check]).join
  break candidate if check < 10 && Ksef::Nip.new(candidate).valid?
end
key = OpenSSL::PKey::RSA.new(2048)               # or OpenSSL::PKey::EC.generate("prime256v1")
cert = OpenSSL::X509::Certificate.new
cert.version = 2
cert.serial = OpenSSL::BN.rand(64)
cert.subject = cert.issuer = OpenSSL::X509::Name.new(
  [["CN", "Test seal"], ["O", "Test seal"], ["2.5.4.97", "VATPL-#{nip}", OpenSSL::ASN1::UTF8STRING], ["C", "PL"]]
)
cert.public_key = OpenSSL::PKey.read(key.public_to_der)
cert.not_before = Time.now - 300
cert.not_after = Time.now + (365 * 86_400)
cert.sign(key, OpenSSL::Digest.new("SHA256"))

client = Ksef::Client.new(config: Ksef.config.with(environment: :test))
result = Ksef::Auth::Coordinator.new(client).authenticate(context: { nip: nip },
                                                          signer: Ksef::Xades::Signer.new(cert: cert, key: key))
```

### Refreshing the access token

```ruby
manager = Ksef::TokenManager.new(client, access_token: result.access_token, refresh_token: result.refresh_token,
                                         access_token_valid_until: result.access_token_valid_until,
                                         on_refresh: ->(token, valid_until) { store(token, valid_until) })   # optional
client = client.with_access_token(-> { manager.access_token })   # read on every request, refreshed 60 s early
```

`on_refresh` lets you persist the new token between requests or jobs; it runs outside the manager's
lock, and one that raises runs again on the next `access_token`. When the refresh token expires or is
revoked (KSeF answers 401), or the authentication no longer allows a refresh (`21301`, `21304`), the
refresh raises `Ksef::ReauthenticationRequired`: authenticate again. `21308` (the credentials of a
deceased person) is a plain `Ksef::BadRequest` — signing in again does not help.

## Invoices

### Invoice XML

`Ksef::Invoices::Builder` writes FA(3) XML from Ruby — parties, lines with any of the ten rates (the
summary is computed), payment, annotations, corrections, footer:

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

- `issue_date` (`P_1`) is the Polish calendar day: KSeF refuses a later one, and marks an invoice dated
  earlier than the day it receives it as issued offline. `Date.today` on a UTC server is the day before
  for the first hour or two after midnight in Poland.
- Quantities and prices are Integers, BigDecimals or strings with a comma or a dot (`"1 234,56"` too);
  prices and discounts take at most 2 decimal places, quantities 6. Anything else raises
  `Ksef::ConfigurationError` naming the line — the builder never writes a guessed amount — and so do
  unknown codes, missing required values and text KSeF refuses. `to_xml` validates its own output
  against the schema (`Ksef::SchemaValidationError` for, say, a value over its length limit).
- What the builder cannot express is refused: a currency other than PLN with a 23/8/5% line (the VAT
  would also have to be stated in PLN), and a `zw` line without `exemption_reason` (the legal basis,
  `P_19A`). An `oo` or `np II` line sets the reverse-charge annotation (`P_18`); a buyer identified by an
  EU VAT number or another tax ID needs `country`.
- A correction (`invoice_type: "KOR"`, with `corrected_date:` and `corrected_number:`) carries the
  change: its totals are summed from its lines, so give difference rows (quantity `"2"` at `"-10.00"` for
  a 20.00 reduction) or the original line negated plus the corrected one.

`Ksef::Invoices::Sample.minimal`, `.typical` and `.full` (`seller_nip:`, `invoice_number:`, `issue_date:`
— the Polish day by default) return builders for three invoices accepted on KSeF TEST; the full one
carries most fields the builder supports, but no payment made, no buyer identified other than by NIP,
no correction or annotation, and five of the ten rates. Their XML ships with the gem in
[`examples/`](examples). For a field the builder does not cover, start from the XML; every field of a
form, with its description from the schema:

```ruby
puts Ksef::Invoices::Validator.new.outline("Faktura/Fa/FaWiersz", descriptions: true)
```

The Ministry's SDKs carry more templates (attachments, `Podmiot3`, FA_RR, PEF):
[C#](https://github.com/CIRFMF/ksef-client-csharp/tree/main/KSeF.Client.Tests.Core/Templates),
[Java](https://github.com/CIRFMF/ksef-client-java/tree/main/demo-web-app/src/integrationTest/resources/xml/invoices/sample).

### Validation

```ruby
validator = Ksef::Invoices::Validator.new   # FA(3); or form_code: Ksef::FormCode::FA_RR1 / FA2
validator.validate(xml)    # => ["...Podmiot2: Missing child element(s)..."], [] when valid
validator.errors(xml)      # => [#<Issue path="Faktura/Podmiot2/DaneIdentyfikacyjne/NIP", line=21, message="...">]
validator.validate!(xml)   # raises Ksef::SchemaValidationError (#messages, #errors)
```

`errors` names the element of each violation, e.g. to show it next to a form field.

The FA(2), FA(3) and FA_RR(1) schemas ship with the gem, so validation works offline; malformed XML
is reported, never repaired; PEF is not supported. Besides the XSD it checks KSeF's XML rules: UTF-8
without a BOM, no other declared encoding, XML 1.0, no processing instructions and none of the
characters KSeF refuses (C1 controls, Unicode noncharacters). What fails here fails on KSeF too; the
messages are libxml2's, not KSeF's.

KSeF also checks what a schema cannot: `KodFormularza` must match the session's form code, the context
must be allowed to invoice for the `Podmiot1` NIP (usually it is that NIP; under self-billing or a tax
representative it is the other party's), the seller NIP, invoice type and `P_2` must not repeat an
earlier invoice, `P_1` must not be later than the day KSeF receives it, and on PROD the NIPs must
have valid check digits.

### Interactive session

The [Quick start](#quick-start) shows the flow. A session takes up to 10,000 invoices and closes by
itself 12 hours after it was opened (`session.valid_until`). `send_invoice` sends the bytes as given,
which must be UTF-8 without a BOM: a BOM or invalid UTF-8 raises `Ksef::ConfigurationError` before
anything is sent.

A rejected invoice makes `wait_for_upo` raise `Ksef::InvoiceRejected` (an `ApiError`) with `#codes`
(`450` schema/semantics, `440` duplicate) and the failed rule in `e.body["status"]["details"]`;
`client.sessions.failed_invoices(ref)` lists every rejection. Any other error from `wait_for_upo` does
not mean a rejection — the invoice may already be accepted, so wait again. These cases need care:

- `Ksef::SessionUnavailable` (`21184`) — the session is under maintenance: continue in a new session.
- A `Ksef::BadRequest` with `21180` (the session is closed or expired) or `21155` (it holds 10,000
  invoices) — continue in a new session.
- `Ksef::NetworkError` (`RequestTimeout` included) on `send_invoice` after the request went out — the
  outcome is unknown: check `client.sessions.invoices(ref)` before sending again. A refused connection,
  a DNS failure or a connect timeout means nothing was sent.

A technical correction — an offline invoice resent after a technical rejection — goes with
`send_invoice(xml, hash_of_corrected_invoice: hash)`, in offline mode (`offline_mode: false` with it
raises). A rotated Ministry key (`21470`) is retried automatically — here and in batch, export and
token authentication.

In background jobs, use one client per worker process, built after it forks, and derive the job's
client from it: `client = KSEF_CLIENT.with_access_token(-> { manager.access_token })` (clients and
sessions do not serialize). A client built in every job holds its own keep-alive socket and CA store
until garbage collection. One session per invoice is capped by the session rate limit
(`client.limits.rate_limits`); after a restart,
`Ksef::Sessions::Online.new(client, reference_number: ref, encryption: nil).wait_for_upo(invoice_ref)`
resumes waiting (without the key such a session can be closed and polled, not sent to).

### Batch session

```ruby
result = Ksef::Batch::Uploader.new(client).call(   # Uploader.new(client, part_size: …) — up to 100 MB, the default
  invoices: { "invoice-1.xml" => xml1, "invoice-2.xml" => xml2 },
  compression: :zip                                # or :tar_gz
)
ref = result.reference_number
status = Ksef::Polling.run(description: "batch #{ref}", timeout: 1800) do
  current = client.sessions.status(ref)
  current.dig("status", "code") < 200 ? Ksef::Polling.pending : current   # 100 started · 150 processing
end
raise "batch #{ref} failed: #{status['status']}" if status.dig("status", "code") >= 400
client.sessions.invoices(ref).each do |invoice|
  puts "#{invoice['invoiceFileName']}: #{invoice['ksefNumber'] || invoice.dig('status', 'description')}"
end
client.sessions.failed_invoices(ref).to_a if status["failedInvoiceCount"].to_i.positive?
```

- `200` means the session was processed and at least one invoice accepted: check
  `failedInvoiceCount` and `client.sessions.failed_invoices(ref)` for the rejected ones. A code of
  400 or more is final — `405` (the package failed verification), `415` (the key could not be
  decrypted), `420` (too many invoices), `430`/`435` (the archive could not be decompressed/decrypted),
  `440` (cancelled), `445` (no valid invoice), `500` — so a wait for `200` alone would never end.
- The package is split into encrypted parts, uploaded and the session closed; the package stays in
  memory, its parts are encrypted one at a time. No invoices, two names that are the same in the
  package (`x.xml` and `:"x.xml"`, `a\b.xml` and `a/b.xml`), an absolute or `..` name, a tar.gz name
  over 100 bytes (`ż` takes 2), or a package over 5 GB or 50 parts raise `Ksef::ConfigurationError`
  before anything is sent. `Result#files` is keyed by the name in the package.
- A failed part upload or close raises `Ksef::BatchUploadError` with the session's `#reference_number`
  (and the part's `#ordinal_number`) — check that session before uploading again.
- Session UPO pages: `status.dig("upo", "pages")` (nil until processed) → `client.sessions.session_upo`.

### Download, metadata and export

```ruby
xml = client.invoices.get_by_ksef_number("5555555555-20250826-0100001AF629-72")

filters = {                                        # camelCase string keys, sent verbatim
  "subjectType" => "Subject1",                     # Subject1 seller · Subject2 buyer · Subject3 · SubjectAuthorized
  "dateRange" => { "dateType" => "Issue",          # Issue | Invoicing | PermanentStorage
                   "from" => "2026-05-01T00:00:00+02:00", "to" => "2026-07-31T23:59:59+02:00" },
  "sellerNip" => "5555555555", "invoiceTypes" => %w[Vat Kor]   # optional, see below
}
client.invoices.query_metadata(filters: filters, sort_order: "Desc").first(50)   # lazy; page_size 10–250 (250)

result = Ksef::Invoices::Export.new(client).call(filters: filters, compression_type: "Zip")   # or "TarGz"
result.metadata                                    # the InvoiceMetadata entries of _metadata.json
result.each_entry { |name, bytes| store(name, bytes) }   # every file — "{ksefNumber}.xml" and _metadata.json
```

- `dateRange` spans at most 100 days (UTC); give dates with `Z` or an offset.
  `restrictToPermanentStorageHwmDate` goes **inside** `dateRange`.
- Optional filters: `ksefNumber`, `invoiceNumber`, `sellerNip`, `buyerIdentifier`
  (`{"type" => "Nip"|"VatUe"|"Other"|"None", "value"}`), `amount` (`{"type" => "Brutto"|"Netto"|"Vat",
  "from", "to"}`), `currencyCodes`, `invoicingMode`, `isSelfInvoicing`, `formType` (`FA`, `PEF`,
  `FA_RR`), `invoiceTypes` (`Vat`, `Zal`, `Kor`, `Roz`, `Upr`, `KorZal`, `KorRoz`, `VatPef`,
  `VatPefSp`, `KorPef`, `VatRr`, `KorVatRr`), `hasAttachment`.
- A filter set yields at most 10,000 records: iterating past them raises `Ksef::ResultTruncated`
  (`#last_item`). Query again from page 0 with `dateRange.from` (ascending) or `dateRange.to`
  (`sort_order: "Desc"`) set to that record's date — the boundary record repeats, dedupe by
  `ksefNumber` — or use `Sync::Incremental`. The endpoint allows 20 requests an hour, hence 250
  records per page by default.
- An export package holds up to 10,000 invoices or 1 GB and is decrypted in memory; every part is
  hash-checked before decryption; an expired package is error `210`. Entry names are never absolute
  or climbing (`..`), and a file over 100 MB unpacked raises.
- An invoice or UPO download is checked against the SHA-256 KSeF sends with it (`x-ms-meta-hash`); a 2xx
  that is not an XML document (a proxy's HTML page, an empty body) raises `Ksef::ApiError`.

### Incremental sync

```ruby
sync = Ksef::Sync::Incremental.new(client, from: last_hwm || (Time.now - (30 * 86_400)), subject_type: "Subject2")
begin
  sync.each_invoice { |xml, meta| upsert(meta["ksefNumber"], xml) }   # stores each invoice before returning
ensure
  save(sync.hwm)                                   # the next run starts here, after an error too
end
```

- It walks windows by permanent-storage date from the HWM until it has caught up; a start more than
  90 days back goes in closed 90-day windows (`dateRange` allows 100). `from:` is a `Time`, a `Date`
  (midnight in Poland) or an ISO 8601 string with `Z` or an offset; one the HWM has not reached yet
  yields nothing (status 420). The first window of a run may repeat the previous run's last invoices,
  so store them by KSeF number.
- Each window is an export, and KSeF allows 20 exports an hour, shared by every sync of the context
  (one per subject type) — so run it no more often than every 15 minutes, and size `page_limit:` (the
  windows per call, 1000 by default) to that budget. A spent budget raises `Ksef::RateLimited` with
  `sync.hwm` at the window it could not export: the `ensure` above saves the progress, and the next
  run resumes there. `poll:` sets the export wait (300 s by default).
- Save `sync.hwm` after an error only when the block stores each invoice before it returns. A consumer
  that buffers (`sync.each_invoice.each_slice(500)`) has not stored the last slice yet: save the HWM
  only after `each_invoice` finished, or after each stored slice.

## Certificates and QR codes

```ruby
csr = Ksef::Crypto::Csr.generate_ecdsa(client.certificates.enrollment_data)   # needs an XAdES session
enrollment = client.certificates.enroll(certificate_name: "Server", certificate_type: "Offline",   # or "Authentication"
                                        csr: csr.csr_der_base64)
client.certificates.enrollment_status(enrollment["referenceNumber"])   # status.code 200 → certificateSerialNumber
client.certificates.retrieve(certificate_serial_numbers: [serial])     # Base64 DER; keep csr.private_key_pem

link = Ksef::Qr::VerificationLink.from_client(client)
code1 = link.online(seller_nip: "5555555555", invoice_xml: xml)   # the date is the invoice's P_1
code2 = link.offline(context_type: "Nip", context_value: "5555555555", seller_nip: "5555555555",
                     certificate_serial: serial, private_key: csr.private_key, invoice_xml: xml)
Ksef::Qr::Code.new(code1, label: ksef_number).as_svg   # label: the KSeF number or "OFFLINE"; "CERTYFIKAT" for CODE II
```

The SVG scales with CSS and keeps the 4-module quiet zone; `as_png` renders the bare code and
`as_ascii` an ANSI terminal preview. `invoice_hash:` plus `issue_date:` (the invoice's `P_1`) instead
of `invoice_xml:` take the `invoiceHash` KSeF returns, Base64 or Base64URL. `certificate_serial:` is the
16 hex digits of `certificateSerialNumber` (or `certificate.serial`); `context_type:` is `"Nip"`,
`"InternalId"`, `"NipVatUe"` or `"PeppolId"` (or `:nip`, … as in authentication). CODE II signs with
the Offline certificate's key: RSA of at least 2048 bits or EC P-256.

## Other resources

`client.tokens`, `client.permissions`, `client.limits`, `client.collective_identifiers`,
`client.peppol`, `client.security` and `client.test_data` (refused on PROD) map 1:1 to the API; lists
are lazy enumerators:

```ruby
client.sessions.list(session_type: "Online", statuses: %w[Succeeded]).first(20)   # plus date_*_from/_to: filters
client.tokens.list(status: %w[Active]).to_a
client.collective_identifiers.generate(invoices: [{ "ksefNumber" => k1 }, { "ksefNumber" => k2 }])
```

`Ksef::Nip#valid?` (the contract pattern and mod 11; `#value` gives the 10 digits without separators or
`PL`) and `Ksef::KsefNumber#valid?` (the contract pattern and CRC-8) check identifiers locally.

## Calling KSeF from a web request

The defaults suit jobs: a request may wait 60 s, a GET is retried twice, and a 429 is slept through for
up to 60 s per retry. In a controller, use a client that fails fast:

```ruby
WEB_KSEF = Ksef::Client.new(config: Ksef.config.with(timeout: 10, open_timeout: 5, max_retries: 0,
                                                     max_retry_after: 0))
```

## Testing your app

`require "ksef/testing"` (needs `webmock`, enabled — `require "webmock/rspec"`, `"webmock/minitest"` or
`WebMock.enable!`; otherwise the stubs are bypassed and the requests reach KSeF) adds WebMock stubs that
answer as KSeF does:

```ruby
require "webmock/rspec"
require "ksef/testing"

include Ksef::Testing
stub_ksef_authentication                                    # token or XAdES sign-in and refresh
stub_ksef_online_session(ksef_number: Ksef::Testing.ksef_number)   # every invoice accepted, with a UPO
```

Each takes `config:` for another environment; other endpoints are stubbed with WebMock directly. The
stubbed Ministry certificate is valid from 2000 to 2099, so tests that travel in time (`travel_to`,
Timecop) work in any order.

## Errors

The gem's own errors, network failures included, inherit from `Ksef::Error`:

| Class | When |
|---|---|
| `ApiError` → `BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Conflict`, `Gone`, `RateLimited` (`#retry_after`), `ServerError` | an HTTP error; `#status`, `#codes` (business codes), `#trace_id`, `#body`. Also an export `status.code` failure (`#status` nil, the code in `#codes`), and a 2xx body that is not what the endpoint returns (not a JSON object, a required field missing, not an XML document) |
| `InvoiceRejected` (an `ApiError`) | KSeF rejected an invoice (`status.code` 400 or more, e.g. `450`, `440` duplicate); `#status` nil, `#body` the invoice status |
| `SessionUnavailable` (a `BadRequest`) | `21184` — the session is under maintenance |
| `ReauthenticationRequired` (an `ApiError`) | the authentication can no longer be used: `21301` (it does not allow it, e.g. its KSeF token was revoked), `21304` (it does not exist — also from the auth status), or a 401 from the refresh: sign in again |
| `NetworkError`, `RequestTimeout` | a transport failure after the retries; `#cause` is the original error. On a call that is not idempotent, any of them after the request went out (a timeout, a reset, a cut-short response) leaves the outcome unknown |
| `AuthenticationFailed` | an authentication `status.code` (e.g. `450` — not an HTTP code) |
| `PollingTimeout`, `SchemaValidationError`, `BatchUploadError`, `ResultTruncated`, `CryptoError`, `ConfigurationError` | too long a wait, invalid XML, a failed batch upload or close, the 10,000-record query limit, a crypto problem, invalid input |

Safe calls are retried automatically (`max_retries`); a POST only after a 429, which KSeF answers
before processing it. Both API error formats (legacy and RFC 7807) are parsed.

## Verification

- **Contract**, on every `rspec` run: `spec/ksef/contract_spec.rb` checks each request — operation,
  path, query (every value of a repeated parameter) and header parameters, tokens, JSON body — against
  the 2.8.1 OpenAPI document in `spec/fixtures/openapi/`, fails when an operation or parameter goes
  unused, walks every list to its second page, and checks the response fields and enums the gem relies
  on. `rake contract:drift` compares that document with what TEST, DEMO and PROD publish.
- **Live**: `rake e2e:test` runs every flow on KSeF TEST with a throwaway self-signed seal for a
  random NIP — no credentials needed — and revokes what it creates.
- **Cryptography**: `rake oracle:all` checks with an independent Python implementation the AES/RSA-OAEP
  output, the KSeF-token plaintext, the CSRs (RDN order and ASN.1 types) and the XAdES signatures
  (digests, SignatureValue, SigningCertificate).

### Checking for KSeF API changes

The contract suite checks the gem against the fixture, not the servers. To see whether KSeF changed
(it ships to TEST first):

```bash
bundle exec rake contract:drift   # TEST, DEMO, PROD vs. the fixture
bundle exec rake e2e:test         # every flow on live TEST
```

On a difference, follow [Moving to a new API version](spec/fixtures/openapi/README.md#moving-to-a-new-api-version).
New invoice schemas are updated by hand ([schemas/README.md](schemas/README.md)).

## Demo application

[`examples/ksef_demo`](examples/ksef_demo) is a Rails 8 test bench for every API area on TEST, DEMO
and PROD (`bundle install && bin/rails server` in its directory). Run it locally only; on PROD the
invoices it sends are legally binding. Details: [its README](examples/ksef_demo/README.md).

## Development

```bash
bundle exec rake                          # rspec (incl. the contract) + rubocop + XSD check of the sample invoice
bundle exec rake "xsd:outline[Faktura/Fa]"   # a form's field tree from the packaged schema
bundle exec rake contract:drift e2e:test oracle:all   # need network
```

## License

MIT — see [`LICENSE.txt`](LICENSE.txt); the bundled XSD schemas and the OpenAPI fixture come from the
Ministry of Finance under MIT ([`NOTICE`](NOTICE)). Provided "as is", without warranty — check results
against KSeF before relying on them for tax obligations. Not affiliated with the Ministry of Finance.
