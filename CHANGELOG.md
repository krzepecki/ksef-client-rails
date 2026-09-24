# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
The gem tracks the KSeF API contract version (currently **2.8.1**, `Ksef::API_VERSION`); every
request is checked against that version's OpenAPI document in the test suite.

## [1.0.0] — 2026-10-14

First functional release: a pure-Ruby client for KSeF API 2.0, covering every operation of the
2.8.1 contract plus high-level flows. Rails integration is optional.

### Added
- **Client and configuration:** `Ksef::Client` facade with 14 domain resources mapped 1:1 to the
  API; global or per-client `Configuration` (`#apply` assigns any option and rejects unknown keys,
  `#with` copies it with some options changed — e.g. another environment);
  TEST, DEMO and PROD environments; option values are type-checked when set, and a client copies the
  configuration it is built with. The access token may be a callable read for every request attempt,
  `with_access_token` derives a per-context client that shares the connection and the key cache, and
  `close` closes the keep-alive connections. One CA store per process.
- **HTTP layer:** retries — a `429` for any call, honouring `Retry-After` up to
  `config.max_retry_after` (60 s by default, `nil` for no limit; a longer wait is raised as
  `Ksef::RateLimited`), and `500`/`502`/`503`/`504` or connection failures for idempotent requests
  (GET, presigned transfers) with exponential backoff — also a GET whose reused TLS connection was
  dropped without close_notify, and any request that never left the process (a connect or a
  connection-pool timeout); transport failures — including the ones Faraday leaves unwrapped, and a
  response cut short of its Content-Length — surface as `Ksef::NetworkError` /
  `Ksef::RequestTimeout`. Keep-alive by
  default (`faraday-net_http_persistent`; `config.adapter` picks another Faraday adapter), array query
  parameters as repeated keys, presigned transfers for batch and export (normalized `https://host` URLs
  only), both pagination schemes as lazy enumerators guarded against a server that never ends them (a
  repeated token, a run of empty pages), polling with backoff, typed errors parsed from both API error
  formats (including the legacy 429 body, the `reasonCode` of a 403 and each problem-details error's
  description). A 2xx body that is not what the endpoint returns — not JSON, not a JSON object, without
  a field the gem needs, or for an invoice or UPO download not an XML document or not matching its
  `x-ms-meta-hash` — raises `Ksef::ApiError` instead of reading as an empty result; a JSON-typed 2xx
  body is never quoted in it (it may carry a token), a non-JSON error body is kept as a short UTF-8
  excerpt. A token with a control character is refused without being echoed. Every HTTP attempt is
  logged at `debug` and published as `request.ksef` through ActiveSupport::Notifications (method, path
  without the query, status).
- **Authentication:** KSeF token (RSA-OAEP) and XAdES-BASELINE-B signature (RSA of at least 2048 bits,
  or EC of at least 256) with a replaceable signer (`#sign(xml)`/`#call(xml)` — HSM, qualified signature
  services; checked, with the context, subject type and allowed IPs, before the challenge is
  requested; its result must be the signed XML), token redemption and refresh, authentication
  sessions, thread-safe `TokenManager` (refreshing at `validUntil`, or at the token's JWT `exp` claim
  when that is not given; `on_refresh`, run outside the lock and again after a failure, to persist each
  new token; `#access_token_valid_until`; a skew longer than the token's lifetime does not refresh on
  every request). A NIP context is sent as its 10 digits, and an invalid one is refused before any
  request. The signer refuses malformed XML, a DOCTYPE, a key without its private part and a
  certificate it does not match; `X509IssuerName` decodes every string type and multi-valued RDNs.
- **Cryptography:** AES-256-CBC session encryption, RSA-OAEP with SHA-256/MGF1-SHA-256, Ministry
  public-key cache (RSA certificates only) with a refetch when the cached list has no valid
  certificate, and a retry on key
  rotation (`21470`) in every flow that wraps a key — online and batch sessions, export (the same
  key re-wrapped under the new certificate) and token authentication (a fresh challenge); PKCS#10
  CSR generation (RSA/EC).
- **Invoices:** interactive session (open → encrypt → send → close → UPO; `valid_until`, a BOM or
  non-UTF-8 invoice refused, a technical correction sent in offline mode, a rejection raised as
  `Ksef::InvoiceRejected`); batch session (ZIP or
  tar.gz — `compression: :zip | :tar_gz` — declared as `batchFile.compressionType`, split into parts
  encrypted one at a time, the contract limits of 50 parts, 5 GB and 100 MB per part checked before
  anything is sent — and so are an empty package, colliding or unsafe names and a tar entry name over
  100 bytes —, UTF-8 ZIP entry names flagged as such, `Ksef::BatchUploadError` naming the session
  when an upload or the close fails); invoice download; metadata queries (250 records per page by
  default, `Ksef::ResultTruncated` at the 10,000-record limit, with the `dateRange` bound to move for
  the sort order); package export (ZIP or tar.gz, checked against `package.compressionType`, streamed
  with `each_entry` — names never absolute or climbing, each file capped at 100 MB unpacked —,
  `_metadata.json` parsed by `metadata`, every part checked against its required `encryptedPartHash`);
  incremental HWM sync (invoices paired with their metadata, a stop once the HWM stops moving, closed
  90-day windows for a start more than 90 days back, nothing yielded while the HWM has not reached the
  start, a `Date` start at Polish midnight, `#hwm` to persist between runs — after an error too).
  Invoices and UPOs are returned as UTF-8 strings.
- **Offline validation:** `Ksef::Invoices::Validator` against the packaged FA(2), FA(3) and
  FA_RR(1) schemas plus KSeF's XML rules (UTF-8 without a BOM, XML 1.0, no processing instructions,
  none of the characters KSeF refuses), without a network call; the messages are libxml2's. The
  XML is parsed strictly (a malformed or namespace-malformed document is reported, never repaired),
  and each schema is parsed once per process. `#errors` gives each violation's element path and line,
  `#outline` a form's field tree with the occurrence of enclosing groups and extension bases (and each
  field's description from the schema on request); `FormCode#namespace` is the invoice namespace.
- **Invoice builder:** `Ksef::Invoices::Builder` writes FA(3) XML — parties (a buyer by NIP, EU VAT
  number, another tax ID or none), lines with the ten rates and their per-rate summary (rounded half
  up), payment, annotations (reverse charge set by an `oo` or `np II` line), corrections (lines as
  differences), footer and registers. Amounts are parsed strictly and written exactly (prices and
  discounts to 2 decimal places, quantities to 6); missing values, unknown codes, a date that is not a
  Date or "YYYY-MM-DD", text KSeF refuses, a foreign-currency invoice with VAT and a `zw` line without
  its legal basis are refused, and the output is checked against the schema.
  `Ksef::Invoices::Sample.minimal`, `.typical` and `.full` are three invoices accepted on KSeF TEST,
  dated with the Polish calendar day by default (`Ksef::PolishTime.today`) and packaged as
  `examples/fa3_{minimal,typical,full}.xml`.
- **QR codes:** CODE I and CODE II links (RSASSA-PSS / ECDSA P-256 signatures with an RSA key of at
  least 2048 bits, every path segment validated — the context type and value against the contract,
  `NipVatUe` values with `+`/`*` included, a 16-hex-digit certificate serial (or `certificate.serial`),
  a seller NIP normalized and checked, the CODE I date read from the invoice's `P_1`, a calendar date
  and a `Time` refused — and KSeF's Base64 `invoiceHash` decoded and checked against the XML) and
  rendering as scalable SVG with the required quiet zone and the label KSeF prescribes (the colour
  validated), PNG or an ANSI terminal preview (optional `rqrcode` gem).
- **Other resources:** collective identifiers (API 2.7+), KSeF tokens, KSeF certificates,
  permissions, limits, security, Peppol, TEST data (refused locally on PROD; includes
  `update_certificate`). `sessions.list` requires the `session_type` the API requires and takes its
  optional filters.
- **Value objects:** `Nip` and `KsefNumber` checked against the contract patterns plus the mod-11
  checksum and CRC-8 (a NIP's separators — no-break spaces and dashes too — and `PL` prefix stripped;
  `Nip.normalize!`; equal only to their own kind), `FormCode`; `Ksef::PolishTime` for the Polish
  calendar day without tzinfo.
- **Rails:** `Ksef::Railtie` (`config.ksef.*` for every option, applied before the app's
  initializers) and the `ksef:install` generator, whose
  initializer sets only the environment — from `KSEF_ENV` when set and not empty, never from
  `Rails.env` — and
  leaves the rest commented out, so it does not override `config.ksef.*`.
- **Errors:** one hierarchy under `Ksef::Error`, including `Ksef::SessionUnavailable` for code
  `21184` (a session under maintenance), `Ksef::ReauthenticationRequired` for `21301`/`21304` and a
  401 from the token refresh (authenticate again), `Ksef::InvoiceRejected` and `Ksef::ResultTruncated`.
- **Testing:** `require "ksef/testing"` — WebMock stubs of the public keys (a certificate valid
  2000–2099, so time travel in tests is safe), sign-in (token and XAdES), refresh and an interactive
  session, with responses checked against the contract.
- **Secret hygiene:** `Ksef::Client`, `Ksef::TokenManager`, the authentication result, session
  encryption data and a generated CSR redact tokens and keys in `#inspect` and in `pp` (the Rails
  console), and an export result or a batch package shows only its size; `Configuration` and the
  connection redact proxy credentials in every form Faraday accepts.
- **Verification tooling:** the contract suite against the 2.8.1 OpenAPI document
  (`spec/fixtures/openapi/`), `rake contract:drift` comparing it with the live servers, and
  `rake e2e:test` running every flow on live KSeF TEST without credentials.
- **Dependencies:** Ruby 3.3 or later; `faraday ~> 2.5`, `faraday-net_http_persistent ~> 2.3`
  (`>= 2.3.1`) with `connection_pool >= 2.4` (the after-fork reset of the keep-alive pool),
  `nokogiri >= 1.19.1, < 2` (the libxml2 security fixes), `rubyzip ~> 3.4` (older releases carry
  CVE-2026-85396), `bigdecimal`, `base64`, `logger`; `rqrcode` and `minitar` are optional.

### Verified
- Offline RSpec suite on Ruby 3.3, 3.4 and 4.0 and at the lowest dependency versions the gemspec
  allows, including the contract check of every request against the KSeF API 2.8.1 OpenAPI document
  (all 83 operations, every parameter and every list's pagination); the built gem loads with its
  runtime dependencies only; cryptography, the KSeF-token plaintext, CSRs and XAdES output (with
  `SigningCertificate`) checked by an independent Python implementation.
- PROD publishes the 2.8.1 contract (`rake contract:drift`, 2026-10-14); TEST and DEMO publish 2.9.0.
- On the live KSeF TEST environment (2026-10-14, `rake e2e:test`, every flow passed; TEST already runs
  API 2.9.0): XAdES authentication with RSA and EC seals, KSeF-token authentication, token refresh,
  authentication sessions, limits, KSeF tokens (with the status filter), interactive session with UPO
  (the three sample invoices included), batch sessions (ZIP in several parts and tar.gz) with UPO and
  every invoice accepted, invoice download checked against its hash, metadata query, export (ZIP and
  tar.gz), `Sync::Incremental` (also from 91 days back: a closed 90-day window, then an open one),
  collective identifiers, Offline certificate enrollment with a CODE II link, permissions, Peppol,
  TEST data, revocations.
- On the live KSeF DEMO environment through the demo application (2026-10-12): authentication (token
  and XAdES), interactive and batch sessions with UPO, export, `Sync::Incremental`, permissions,
  certificate enrollment and offline QR; on the live KSeF PROD environment (2026-10-12):
  authentication with a KSeF token. A GET was retried live after a dropped keep-alive connection, and
  a 429 slept through and retried.
- The Railtie and the `ksef:install` generator smoke-tested in a Rails 8.1 application.

### Known limitations
- Not exercised live: the 5xx retries, `SessionUnavailable` and a token refresh refused with 401.
  The Railtie and the generator are not exercised by the demo application.
- No HTML/PDF invoice rendering, no PEF (UBL) schema validation. The builder writes VAT and KOR
  invoices only (no advance, settlement or simplified invoices, no `Podmiot3`, no attachments), in PLN
  when a line carries VAT, and a correction as difference lines (no `StanPrzed`).
- Batch and export packages are held in memory (one copy of the package).
- With the default keep-alive adapter, a proxy password containing percent-encoded characters fails
  (`URI::InvalidComponentError`, faraday-net_http_persistent 2.3); use `adapter: :net_http`.

## [0.1.0] — 2026-09-24

Name reservation only; no functionality.
