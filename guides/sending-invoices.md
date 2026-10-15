# Sending invoices

Invoices go to KSeF inside a **session**. There are two kinds:

| | Interactive session | Batch session |
|---|---|---|
| How | one request per invoice | all invoices in one encrypted package (ZIP or tar.gz) |
| Use it for | invoices sent as you issue them | many invoices at once |
| Limit | 10,000 invoices per session | 5 GB or 50 parts per package |

For each accepted invoice, KSeF assigns a **KSeF number** and issues a **UPO**, the official
receipt.

## Interactive session

```ruby
session = Ksef::Sessions::Online.open(client)
sent = session.send_invoice(invoice_xml)               # encrypted and hashed by the gem
session.close
upo = session.wait_for_upo(sent.reference_number)      # waits until accepted; the UPO XML
ksef_number = client.sessions.invoice(session.reference_number, sent.reference_number)["ksefNumber"]
```

- Send many invoices in one session rather than one session per invoice: KSeF limits how many
  sessions you may open (`client.limits.rate_limits`).
- A session closes by itself 12 hours after it was opened (`session.valid_until`).
- The XML must carry the context's NIP in `Podmiot1`, or a NIP the context may invoice for.
- The invoice must be UTF-8 without a BOM. Otherwise `send_invoice` raises
  `Ksef::ConfigurationError` before anything is sent.
- The QR code printed on the invoice: [QR codes](certificates-and-qr-codes.md#qr-codes).

### When something fails

| Error | What it means | What to do |
|---|---|---|
| `Ksef::InvoiceRejected` from `wait_for_upo` | KSeF rejected the invoice: `#codes` holds `450` (schema or content) or `440` (duplicate) | the reason is in `e.body["status"]["details"]` |
| any other error from `wait_for_upo` | not a rejection — the invoice may already be accepted | wait again |
| `Ksef::SessionUnavailable` (`21184`) | the session is under maintenance | continue in a new session |
| `Ksef::BadRequest` with `21180` | the session is closed or expired | continue in a new session |
| `Ksef::BadRequest` with `21155` | the session already holds 10,000 invoices | continue in a new session |
| `Ksef::NetworkError` or `RequestTimeout` from `send_invoice`, after the request went out | the invoice may or may not have arrived | check `client.sessions.invoices(ref)` before sending it again |

- `client.sessions.failed_invoices(ref)` lists every rejected invoice of a session.
- A refused connection, a DNS failure or a connect timeout means nothing was sent.
- When the Ministry rotates its encryption key (`21470`), the gem retries by itself — here and in
  batch sessions, exports and token sign-in.

## Batch session

The gem builds the package, encrypts it, uploads it in parts and closes the session. KSeF then
processes it, and you wait for the result:

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

**Session status** (`status.code`). Wait while it is below 200. A code of 400 or more is final —
waiting for `200` alone could never end:

| Code | Meaning |
|---|---|
| `100`, `150` | started, processing |
| `200` | processed, at least one invoice accepted — check `failedInvoiceCount` and `client.sessions.failed_invoices(ref)` for the rejected ones |
| `405` | the package failed verification |
| `415` | the key could not be decrypted |
| `420` | too many invoices |
| `430` / `435` | the archive could not be decompressed / decrypted |
| `440` | cancelled |
| `445` | no valid invoice |
| `500` | unknown error |

- If a part upload or the close fails, the gem raises `Ksef::BatchUploadError` with the session's
  `#reference_number` (and the part's `#ordinal_number`). Check that session before uploading again.
- `Result#files` is keyed by the file names in the package.
- The session's UPO: `status.dig("upo", "pages")` (nil until processed) → `client.sessions.session_upo`.

<details>
<summary>Edge cases</summary>

- **Technical correction** (an offline invoice sent again after a technical rejection):
  `send_invoice(xml, hash_of_corrected_invoice: hash)`. It goes in offline mode; `offline_mode: false`
  with it raises.
- **Resuming after a restart:**
  `Ksef::Sessions::Online.new(client, reference_number: ref, encryption: nil).wait_for_upo(invoice_ref)`
  waits again. Without the encryption key, such a session can be closed and polled, not sent to.
- **Batch packages are built in memory.** The parts are encrypted one at a time.
- **Refused before anything is sent** (`Ksef::ConfigurationError`): no invoices; two names that end
  up the same in the package (`x.xml` and `:"x.xml"`, `a\b.xml` and `a/b.xml`); an absolute or `..`
  name; a tar.gz name over 100 bytes (`ż` takes 2); a package over 5 GB or 50 parts.
- `InvoiceRejected` is an `ApiError`.

</details>
