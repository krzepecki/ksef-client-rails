# Other resources

The flows in the other guides cover the common tasks. For everything else, the client exposes each
area of the KSeF API as an object whose methods map 1:1 to the API's endpoints:

| Object | What it covers |
|---|---|
| `client.auth` | sign-in steps, token refresh, active sign-in sessions |
| `client.sessions` | sessions: list, status, their invoices (rejected ones too), UPOs |
| `client.online`, `client.batch` | the raw endpoints of interactive and batch sessions |
| `client.invoices` | downloading an invoice, searching metadata |
| `client.exports` | the raw export endpoints |
| `client.certificates` | KSeF certificates: requests, limits, listing, download, revocation |
| `client.tokens` | KSeF tokens: generate, list, check, revoke |
| `client.permissions` | permissions: grant, revoke, query |
| `client.limits` | the limits in force and the API rate limits |
| `client.collective_identifiers` | one number for a set of invoices of one seller, e.g. for a single payment |
| `client.peppol` | the list of Peppol providers |
| `client.security` | the Ministry of Finance's public-key certificates |
| `client.test_data` | test data: entities, persons, permissions (refused on PROD) |

Lists are lazy: pages are fetched as you iterate.

```ruby
client.sessions.list(session_type: "Online", statuses: %w[Succeeded]).first(20)   # plus date_*_from/_to: filters
client.tokens.list(status: %w[Active]).to_a
client.collective_identifiers.generate(invoices: [{ "ksefNumber" => k1 }, { "ksefNumber" => k2 }])
```

## Checking identifiers locally

- `Ksef::Nip#valid?` checks a NIP: its format and check digit. `#value` gives its 10 digits, without
  separators or `PL`.
- `Ksef::KsefNumber#valid?` checks a KSeF number: its format and checksum (CRC-8).
