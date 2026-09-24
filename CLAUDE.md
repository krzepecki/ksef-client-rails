# CLAUDE.md — working on `ksef-client-rails`

A pure-Ruby client for the Polish KSeF API 2.0 (contract 2.8.1). Module `Ksef`, gem name
`ksef-client-rails`, require path `ksef`. No hard dependency on Rails; the Railtie loads only when
Rails is present.

How to use it: [`README.md`](README.md).

## Layout

| Path | What lives there |
|---|---|
| `lib/ksef/` | The gem: facade, resources, HTTP, crypto, XAdES, flows, FA(3) builder |
| `lib/generators/ksef/install/` | `rails g ksef:install` (initializer template) |
| `schemas/` | Packaged FA(2)/FA(3)/FA_RR(1) XSDs + base types; update procedure in `schemas/README.md` |
| `spec/` | RSpec, offline (WebMock) |
| `gemfiles/minimum.gemfile` | The lowest runtime versions the gemspec allows; CI runs the suite against them |
| `spec/fixtures/openapi/` | The KSeF OpenAPI document of `Ksef::API_VERSION`; `spec/ksef/contract_spec.rb` checks every request against it (update procedure in its README) |
| `tools/oracle/` | Independent Python checks of the crypto and XAdES output |
| `tools/e2e_test_env.rb` | Every flow on live KSeF TEST, no credentials (a self-signed seal for a random NIP) |
| `tools/openapi_drift.rb` | The OpenAPI fixture vs. what TEST/DEMO/PROD publish now |
| `tools/e2e_online.rb`, `tools/diagnose_session.rb` | Manual runs with your own KSeF token |
| `examples/ksef_demo/` | Rails 8 demo app / manual test bench (see its README) |
| `examples/fa3_{minimal,typical,full}.xml` | `Ksef::Invoices::Sample` as XML, packaged with the gem; `rake xsd:examples` writes them |

## Commands

```bash
bundle exec rake                 # rspec + rubocop + XSD validation of the sample invoice
bundle exec rspec
bundle exec rubocop              # covers examples/ too
bundle exec rake oracle:all      # Python oracle; first run creates tools/oracle/venv (needs network)
bundle exec rake contract:drift  # fixture vs. live servers (needs network)
bundle exec rake e2e:test        # live KSeF TEST run (needs network)
bundle exec rake "xsd:validate[invoice.xml]"
bundle exec rake "xsd:outline[Faktura/Fa]"
bundle exec rake xsd:examples    # regenerate examples/fa3_*.xml from Ksef::Invoices::Sample
```

## Decisions not to undo

Each of these is confirmed by the oracle, the official SDKs or a live TEST/DEMO run.

| Topic | Decision |
|---|---|
| API path prefix | `/v2`, not `/api/v2` |
| AES payload | Plain ciphertext, **no IV prefix**; the IV travels only in `EncryptionInfo` |
| RSA-OAEP | SHA-256 for the digest **and** MGF1 |
| XAdES `DigestMethod` | `http://www.w3.org/2001/04/xmlenc#sha256` (`xmldsig#sha256` → 9105) |
| ECDSA signature | R‖S (IEEE P1363), not DER — in XAdES and QR CODE II |
| XAdES canonicalization | Exclusive c14n, named explicitly |
| XAdES issuer DN | RFC 2253 short names only for `CN L ST O OU C STREET DC UID`, `OID.x.y.z` otherwise |
| CSR subject | Enrollment data in the C# RDN order and ASN.1 types |
| Offset pagination | `pageOffset` is a 0-based page index |
| Continuation token | Read from the body, sent in the `x-continuation-token` header |
| Array query parameters | Repeated keys (`status=A&status=B`, `FlatParamsEncoder`), not `status[]=A` — as the C# SDK sends them |
| Invoice filters | `restrictToPermanentStorageHwmDate` goes inside `dateRange` |
| Tokens | Never global; every call takes its `bearer:` |
| Anonymous endpoints | No token where the contract declares no security — including `/peppol/query` (confirmed on TEST, DEMO and PROD 2.8.1) and `/testdata/context/block|unblock` (TEST) |
| `Sync::Incremental` | A non-truncated window continues from `permanentStorageHwmDate`; the loop stops on an empty window (and, as a guard, when the HWM does not advance). A start older than 90 days goes in closed windows (`dateRange.to = from + 90 days`, under the 100-day limit) that continue from `to` — or a lower HWM — even when empty; the stop rules apply to the open-ended window |

## Verification status

- Contract 2.8.1: every request is checked against the OpenAPI fixture on each `rspec` run (all 83
  operations and every parameter, path parameters and every value of a repeated one, every list to
  its second page). `rake contract:drift` (2026-10-14): PROD publishes 2.8.1, the fixture; TEST and
  DEMO moved to 2.9.0 on 2026-10-13 (adds `OwnerPermissionScope`, changes
  `QueryPersonalPermissionsResponse`) — the fixture and `Ksef::API_VERSION` are still 2.8.1.
- Live KSeF TEST (2.9.0): `rake e2e:test` on 2026-10-14, after the 1.0.0 review fixes — every flow
  passed (the three sample invoices, batch checked invoice by invoice, invoice and UPO downloads
  checked against `x-ms-meta-hash`, `Sync::Incremental` from 91 days back); 35/36 steps, the one
  failure being the version guard (server 2.9.0, contract 2.8.1).
- Before the review fixes (2026-10-12): DEMO — every feature through the demo app; PROD — token
  authentication; a fresh Rails app (`rails new` 8.1.4 with Tailwind, the gem installed from its built
  package, the generator, the Railtie, jobs on Solid Queue in `RAILS_ENV=production`) ran every panel
  flow on TEST, and a GET was retried live after a dropped keep-alive connection. Not repeated since.
- Packaging (2026-10-14): the built gem in an empty `GEM_HOME` (runtime dependencies only) loads and
  builds an invoice on Ruby 3.4.4 and 4.0.1; the suite passes at the lowest allowed versions on Ruby
  3.4.4 (Ruby 3.3 only in CI).
- 429 handling exercised live on TEST: a `Retry-After` of 1 s and 59 s slept through and retried,
  the hourly limit raised as `Ksef::RateLimited`.
- Not exercised live: the 5xx retries, `SessionUnavailable` (21184) and a refresh refused with 401
  (`ReauthenticationRequired`; whether KSeF answers an expired refresh token with 401 or 400 is
  unconfirmed). Keep the README status note in sync with this.

## Gotchas

- The demo loads the gem as a path dependency: restart `bin/rails server` after changing `lib/`,
  and after changing the demo's `config/`.
- `Ksef::Invoices::Builder` was ported from the demo's renderer byte for byte; the demo's
  `InvoiceDraft` subclasses it. `Sample.minimal` is the document accepted on live TEST since the first
  release — keep its output identical. `rake e2e:test` sends all three samples; after changing the
  builder or `Sample`, run `rake xsd:examples` (the spec compares `examples/*.xml` with `Sample`).
- Resource responses are plain hashes; don't add models that reject unknown fields. Where a flow
  needs a field, the resource call names it (`returns: %w[referenceNumber]`) and a 2xx without it
  raises; keep that list to the keys the gem reads, not every key the contract marks required.
- `spec.files` takes git-tracked files only: `git add` a new file under `lib/`, `schemas/` or
  `examples/` before `gem build`, or it is left out of the package.
- Ruby 3.3+. The dependency floors in the gemspec are deliberate (bigdecimal, connection_pool for
  fork safety, nokogiri for the libxml2 fixes); the `minimum` CI job runs at them.
- A new endpoint or parameter in the OpenAPI fixture fails the contract suite's coverage check until
  the gem supports it — that is the point; bump the fixture and `Ksef::API_VERSION` together.
- KSeF's `status.code` values (100/200/440/450/…) arrive inside HTTP 200 responses.
- The builder refuses rather than guesses: amounts with more than 2 decimal places (P_9A/P_10), a
  foreign currency with a VAT line, a `zw` line without `exemption_reason`, a tar.gz entry name over
  100 bytes. Lifting one of these is a feature, with its own tests and a live TEST run.

## Code conventions

- All code, comments and documentation are in English.
- Comments stay brief: class headers ≤3 lines (what it is + the one non-obvious decision), no
  `@example` blocks in `lib/` (usage lives in README), `@param`/`@return` on public methods.
  Nothing that merely restates the code or duplicates a constant below it.
- Endpoint paths live as constants at the top of each resource class.
- RuboCop with relaxed metrics for crypto/XAdES (see `.rubocop.yml`).
