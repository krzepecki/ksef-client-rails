# KSeF — demo application (Rails)

A small Rails application (no database, no asset pipeline) that exercises every area of the
`ksef-client-rails` gem and serves as a manual test bench. It works against all three KSeF
environments — TEST, DEMO and PROD — switched on the Overview page (see
[Environments](#environments)).
Styled with Tailwind CSS via its browser build (a `<script>` from jsDelivr, pinned to one version with
a Subresource Integrity hash — fine for a local demo, not a production setup).

## Running it

```bash
cd examples/ksef_demo
bundle install
bin/rails server        # http://localhost:3000
```

> The `ksef-client-rails` gem is loaded from a local path (`gem "ksef-client-rails", path: "../.."`).

> **Local use only — never expose the demo on a network.** It is built as a single-user test bench:
> a fixed `secret_key_base`, host checks switched off (`config.hosts.clear`), full error pages for
> every request, and the tokens of whoever signs in held in the server's memory. Generated files
> (private keys, export packages) can be downloaded only by the browser session that created them;
> export packages over 8 MB wait in `tmp/downloads/` for 30 minutes, everything else stays in memory.
> The request log (`log/development.log` and the server console) shows passwords, tokens, keys,
> certificates and invoice contents as `[FILTERED]` (`config.filter_parameters`).

The configuration (environment, context NIP, timeout, XAdES enforcement) and the access/refresh
tokens live in a **server-side session** (Rails `:cache_store` backed by `:memory_store` — a token
pair does not fit in a 4 KB cookie). Restarting the server signs you out; switching the environment
does too, because tokens are valid only in the environment that issued them. All tabs share that
session, so every form also sends the environment and context NIP its page showed: when the session
has moved to another one since (another tab, or a long request there writing back its settings), the
demo answers "Nothing was sent" instead of calling KSeF.

## Environments

| | TEST | DEMO | PROD |
|---|---|---|---|
| Purpose | integration testing (release candidates) | final checks in production-like conditions | invoices with full legal effect |
| Sign-in | KSeF token, or any certificate — **self-signed accepted** | KSeF token, or a qualified certificate / KSeF certificate | KSeF token, or a qualified certificate / KSeF certificate |
| Data | shared between all integrators — use random NIPs (with a valid check digit), never real data | test data only, no real invoices | **real** — every invoice sent is legally binding |
| Test data page | available | not intended (TEST feature) | refused by the demo |

- **TEST** is the default and the right place to start: a self-signed seal certificate (see
  [Notes](#notes)) or a KSeF token generated there is enough.
- **DEMO and PROD** need real credentials for the context NIP — a KSeF token generated for that
  environment, or a qualified certificate (personal or organization seal) or KSeF certificate.
  The demo signs in with an uploaded certificate file or a token; it does not support Profil
  Zaufany.
- **On PROD, "Issue invoice" and "Batch session" send real invoices.** Replace the sample parties
  and amounts with real data, and do not use the demo for anything you would not issue by hand.

## Pages

| Page | What it shows | Gem API | Needs |
|---|---|---|---|
| **Overview** | settings, connectivity check, map of the demo | `security.public_key_certificates` | nothing |
| **Authentication** | KSeF token, XAdES certificate, pasted tokens; refresh, auth sessions, sign out | `Auth::Coordinator`, `Xades::Signer`, `auth.*` | a KSeF token or a certificate |
| **Issue invoice** | four tabs — Typical, Full, All fields (every FA(3) element), XML — with live totals and XSD preview; the result page draws a step-by-step timeline with KSeF number, UPO download and CODE I QR | `InvoiceDraft`/`SchemaForm` (demo), `Invoices::Validator`, `Sessions::Online` | access token |
| **Browse invoices** | download by KSeF number, metadata query | `invoices.get_by_ksef_number`, `invoices.query_metadata` | access token |
| **QR codes** | CODE I (online) and CODE II (offline, certificate-signed) | `Qr::VerificationLink`, `Qr::Code` | nothing / an Offline certificate |
| **Sessions & UPO** | online/batch session list, invoices, rejections with `status.details`, invoice and session UPO | `sessions.*` | access token |
| **Batch session** | N copies of the invoice on Issue invoice (the last one previewed or sent there, from any tab, or the sample) in one ZIP/tar.gz, split into encrypted parts | `Batch::Uploader` | access token |
| **Export & sync** | encrypted package export (ZIP or tar.gz, downloadable), bounded incremental HWM sync showing where the next run starts | `Invoices::Export`, `Sync::Incremental` | access token |
| **KSeF tokens** | generate (with permissions), list, status, revoke | `tokens.*` | access token |
| **Certificates** | limits, enrollment data, CSR (EC/RSA) + enrollment, status, list, retrieve (PEM), revoke | `certificates.*`, `Crypto::Csr` | XAdES-authenticated session |
| **Permissions** | 11 curated queries, grant to a person, operation status, revoke | `permissions.*` | access token |
| **Limits** | context, subject and API rate limits | `limits.*` | access token |
| **Test data** | create/remove test subjects (VAT groups, JST, enforcement authorities), persons, test permissions | `test_data.*` | nothing — TEST only; the demo refuses these calls on PROD |

A typical run: **Overview → Check connection**, **Authentication**, then **Issue invoice**.
Signing in with an identifier that carries the context NIP (e.g. a seal with `VATPL-<NIP>`) makes
you the owner of that context automatically — no test data is needed for that. The **Test data**
page is for the other scenarios: sole traders and bailiffs (persons), VAT groups, JST and
enforcement authorities (subjects), and permissions for other identifiers.

### The invoice form

| Tab | What it covers | How the XML is made |
|---|---|---|
| **Typical** | seller, buyer (NIP or consumer), dates, lines with 23/8/5/0/zw, payment | `InvoiceDraft` → `Ksef::Invoices::Builder` (server) |
| **Full** | Typical plus: correction (`KOR` with `DaneFaKorygowanej`), annotations (MPP, reverse charge, cash accounting, self-billing, triangular), rates 0 WDT/0 EX/np I/np II/oo, EU/foreign buyer, contact data, footer (KRS/REGON/BDO), line details (index, GTIN, PKWiU, CN, GTU, discount `P_10`), paid flag | same, more fields |
| **All fields** | every element of `schemat_FA(3)` (406 elements, choices, repeated items), generated from the XSD | serialized in the browser |
| **XML** | the document itself, sent as-is | — |

- `app/models/invoice_draft.rb` — the form model: a subclass of the gem's `Ksef::Invoices::Builder`
  (VAT summed per rate group, a `zw` line switches `Zwolnienie` to `P_19` + `P_19A`) with the form's
  labels and params parsing; `Podmiot1/NIP` is always the session context. `InvoiceDraft.sample` is
  `Ksef::Invoices::Sample.minimal`, `sample(full: true)` is `Sample.typical`.
- Quantity, price and discount inputs carry the number formats the builder reads as `pattern`s
  (`1234,56`, `1 234,56`), and the live totals parse and round them the same way, in exact decimals.
  Whatever the builder still refuses (a NIP checksum, a `zw` line without its legal basis, a payment
  date without "Already paid"…) comes back as an error next to "Send to KSeF", with nothing sent.
- Full-only inputs live in `fieldset[data-full-only]`, disabled on Typical, so they are not
  submitted there. Each tab panel is a fieldset disabled while hidden.
- `app/models/schema_form.rb` reads the XSD (plus `bazowe/` types) into elements and
  sequence/choice groups with their own cardinality; `app/helpers/schema_form_helper.rb` renders
  it prefilled from the current XML. Inputs have no names: on submit the browser walks the DOM
  (`data-x` element, `data-xval` text, `data-xattr` attribute) and leaves empty elements out; only
  the selected branch of a choice is sent. The tab checks structure only — no totals are computed,
  and KSeF's business rules can still reject an XSD-valid invoice. `window.ksefSchemaXml()` returns
  the serialized document in the browser console.
- The result page is driven by `app/models/invoice_submission.rb`, which records the status and
  duration of every step (validate → open → send → close → UPO → KSeF number). A failed send still
  closes the session; one that broke off in transit, or whose processing result did not arrive, is
  reported as an unknown outcome — check the session before sending again.
- Per-form CSRF tokens are off (`ApplicationController`): several forms submit through extra
  `formaction` buttons, which per-form tokens reject with 422.

## Notes

- An `FV/DEMO/…` invoice number is refreshed on every send, on every tab — an identical invoice
  would be rejected as a duplicate (code 440). The Typical and Full tabs always add the
  `Podmiot2/JST` and `Podmiot2/GV` markers FA(3) requires — without them KSeF answers 450
  ("Błąd weryfikacji semantyki dokumentu faktury").
- "Issue invoice" validates locally (`Ksef::Invoices::Validator`) **before** opening a session —
  a schema mismatch costs no round trip. On the XML and All fields tabs, **"Skip local XSD
  validation"** sends anyway, to observe KSeF's own rejection with `status.details`; the Typical and
  Full tabs always pass the builder's own schema check. From the command line:
  `bundle exec rake "xsd:validate[invoice.xml]"` in the gem directory.
- Diagnosing a rejected invoice: `bundle exec ruby tools/diagnose_session.rb` from the gem
  directory (see the script header) — it prints `status.details` and `sessions.failed_invoices`.
- A full e2e run from the command line (no browser): `bundle exec ruby tools/e2e_online.rb` — TEST
  unless `KSEF_ENV` is set; PROD needs `KSEF_CONFIRM_PROD=1` and an invoice file (see the script
  header).
- Authentication **with a certificate** (`Ksef::Xades::Signer` +
  `Ksef::Auth::Coordinator#authenticate`) takes a certificate + key pair (PEM or DER), both in one
  PEM file, or a PKCS#12 (`.p12`/`.pfx`); the password field covers both PKCS#12 and an encrypted
  key. RSA and EC P-256 keys both work. File fields are
  not sticky — pick the file again on every attempt. The pair KSeF issues (`*.cert` + `*.key`) goes into the two upload fields
  as-is — the certificate is read as PEM or DER, and the key as PEM or DER, encrypted or not.
- **The gem is a path dependency (`gem "ksef-client-rails", path: "../.."`), so its code is loaded once at
  boot — Rails does not reload it.** After any change under `lib/` in the gem, restart
  `bin/rails server`; a browser refresh keeps running the old code.
- The certificate login prints a **Signature diagnostics** panel: certificate subject/issuer,
  validity, SHA-256 fingerprint, whether the key matches the certificate, and the exact signed XML
  that went to `POST /auth/xades-signature`. That XML holds the public certificate only — no
  private key — so it is safe to attach to a bug report. KSeF answers `9105` ("Nieprawidłowy
  podpis") for every signature problem without saying which, so those bytes are the starting point.
- **What the certificate must contain.** With `SubjectIdentifierType = certificateSubject` KSeF
  matches the context tax id against the certificate subject: a qualified **seal** (organization)
  needs `organizationIdentifier` (OID 2.5.4.97) matching `VATPL-<NIP>` and must not carry
  `givenName`/`surname`; a **personal** qualified certificate needs `serialNumber` (OID 2.5.4.5)
  matching `TINPL-<NIP>`/`NIP-<NIP>` or `PNOPL-<PESEL>`. A certificate without those identifiers
  authenticates only as `certificateFingerprint`, after permissions have been granted to its
  SHA-256 fingerprint.
- **Self-signed certificates are accepted on TEST only.** On DEMO/PRD the signature has to come
  from a qualified certificate (personal, or an organization seal), a Trusted Profile, or a
  [KSeF certificate](https://github.com/CIRFMF/ksef-api/blob/main/certyfikaty-KSeF.md). A test
  seal certificate for TEST:
  ```bash
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
    -keyout demo_key.pem -out demo_cert.pem \
    -subj "/C=PL/O=Demo sp. z o.o./CN=Demo/2.5.4.97=VATPL-<NIP>"
  cat demo_cert.pem demo_key.pem > demo_bundle.pem   # a single file for the upload field
  ```
  `-nodes` leaves the private key **unencrypted** — these are throwaway TEST files, delete them
  when you are done. Use a random NIP with a valid check digit (Overview refuses any other): TEST
  data is shared between integrators, and anyone can sign in to the same context with their own
  self-signed certificate.
