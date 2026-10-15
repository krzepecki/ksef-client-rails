# Receiving invoices

KSeF stores the invoices you issued and the ones others issued to you. There are four ways to get
them:

| Way | Use it when |
|---|---|
| [Download one invoice](#download-one-invoice) | you know its KSeF number |
| [Search](#search-invoices) | you want a list of invoices matching filters, then download some |
| [Export](#export) | you want many invoices at once, as one package |
| [Incremental sync](#incremental-sync) | you want to keep a local copy up to date, run after run |

## Download one invoice

```ruby
xml = client.invoices.get_by_ksef_number("5555555555-20250826-0100001AF629-72")
```

KSeF sends the invoice's SHA-256 with it (`x-ms-meta-hash`); the gem checks the download against it,
and does the same for UPOs. A response that is not an XML document (a proxy's HTML page, an empty
body) raises `Ksef::ApiError`.

## Search invoices

A search returns **metadata** — number, parties, amounts, KSeF number — not the invoice itself. The
result is lazy: pages are fetched as you iterate (`page_size` 10–250, 250 by default).

```ruby
filters = {                                        # camelCase string keys, sent verbatim
  "subjectType" => "Subject1",                     # Subject1 seller · Subject2 buyer · Subject3 · SubjectAuthorized
  "dateRange" => { "dateType" => "Issue",          # Issue | Invoicing | PermanentStorage
                   "from" => "2026-05-01T00:00:00+02:00", "to" => "2026-07-31T23:59:59+02:00" },
  "sellerNip" => "5555555555", "invoiceTypes" => %w[Vat Kor]   # optional, see below
}
client.invoices.query_metadata(filters: filters, sort_order: "Desc").first(50)
```

- `subjectType` says which side you are on: `Subject1` — the seller, `Subject2` — the buyer,
  `Subject3` — a third party on the invoice (`Podmiot3`), `SubjectAuthorized` — an authorized entity.
- `dateRange` spans at most 100 days. Give the dates with `Z` or an offset.
- `restrictToPermanentStorageHwmDate` goes **inside** `dateRange`.
- KSeF allows 20 searches an hour, hence the large default page.

**Optional filters:**

| Filter | Values |
|---|---|
| `ksefNumber`, `invoiceNumber`, `sellerNip` | |
| `buyerIdentifier` | `{"type" => …, "value" => …}`; `type`: `Nip`, `VatUe`, `Other`, `None` |
| `amount` | `{"type" => …, "from" => …, "to" => …}`; `type`: `Brutto`, `Netto`, `Vat` |
| `currencyCodes`, `invoicingMode`, `isSelfInvoicing`, `hasAttachment` | |
| `formType` | `FA`, `PEF`, `FA_RR` |
| `invoiceTypes` | `Vat`, `Zal`, `Kor`, `Roz`, `Upr`, `KorZal`, `KorRoz`, `VatPef`, `VatPefSp`, `KorPef`, `VatRr`, `KorVatRr` |

**More than 10,000 results.** One search returns at most 10,000; iterating past them raises
`Ksef::ResultTruncated`. To continue, take the date of its `#last_item` and search again from page 0,
with that date as `dateRange.from` (ascending) or `dateRange.to` (`sort_order: "Desc"`). The boundary
record comes back twice, so dedupe by `ksefNumber` — or use the [incremental sync](#incremental-sync).

## Export

An export gives you the invoices themselves, many at once, in one encrypted package. The gem waits for
KSeF to prepare it, downloads and decrypts it:

```ruby
result = Ksef::Invoices::Export.new(client).call(filters: filters, compression_type: "Zip")   # or "TarGz"
result.metadata                                    # the InvoiceMetadata entries of _metadata.json
result.each_entry { |name, bytes| store(name, bytes) }   # every file — "{ksefNumber}.xml" and _metadata.json
```

- A package holds up to 10,000 invoices or 1 GB, and is decrypted in memory.
- Each part is checked against its hash before decryption.
- An expired package is error `210`.

## Incremental sync

Keeps a local copy of your invoices up to date. Each run downloads what is new since the previous run
and returns a bookmark, `sync.hwm`, to save for the next one:

```ruby
sync = Ksef::Sync::Incremental.new(client, from: last_hwm || (Time.now - (30 * 86_400)), subject_type: "Subject2")
begin
  sync.each_invoice { |xml, meta| upsert(meta["ksefNumber"], xml) }   # stores each invoice before returning
ensure
  save(sync.hwm)                                   # the next run starts here, after an error too
end
```

**How it works.** KSeF keeps a high-water mark (HWM): the point up to which its storage is complete.
The sync exports invoices window by window, by storage date, from your bookmark up to the HWM. A start
more than 90 days back goes in 90-day windows (`dateRange` allows 100).

- `from:` is a `Time`, a `Date` (midnight in Poland) or an ISO 8601 string with `Z` or an offset.
- The first window of a run may repeat the previous run's last invoices, so store them by KSeF number.
- KSeF allows 20 exports an hour, and each window is one export. The limit is shared by every sync of
  the context (one per subject type), so run the sync at most every 15 minutes.
- `page_limit:` caps the windows per run (1000 by default); `poll:` sets how long to wait for each
  export (300 s by default).
- When the hourly limit runs out, the sync raises `Ksef::RateLimited`, and `sync.hwm` points at the
  window it could not export. The `ensure` above saves that, so the next run continues there.

<details>
<summary>Edge cases</summary>

- **Saving the bookmark after an error** is safe only when the block stores each invoice before it
  returns. A consumer that buffers (`sync.each_invoice.each_slice(500)`) has not stored the last slice
  yet: save `sync.hwm` only after `each_invoice` finished, or after each stored slice.
- **A `from:` the HWM has not reached yet** returns nothing (status 420).
- **Export file names** are never absolute or climbing (`..`), and a file over 100 MB unpacked raises.

</details>
