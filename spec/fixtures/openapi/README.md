# KSeF OpenAPI document (contract fixture)

`ksef-api-2.8.1.json` is the OpenAPI document the KSeF TEST server publishes at
<https://api-test.ksef.mf.gov.pl/docs/v2/openapi.json>, downloaded unchanged on 2026-10-12:
API **2.8.1**, build `2.8.1-te-20261007.1+33b3a4825d8449c8514335d9ba1c1bddcc622d0d`, SHA-256
`dfef3ea0037ecfd9f2344e28cf70cc4c454df93ae69f9e54560dbf40fcd1b139`. It has the same operations and
schemas as `open-api.json` in [CIRFMF/ksef-api](https://github.com/CIRFMF/ksef-api) at the 2.8.1
release, and the DEMO and PROD servers publish the same contract (without the TEST-only `/testdata`
endpoints; descriptions aside).
Copyright (c) Ministerstwo Finansów, MIT licence — see [`NOTICE`](../../../NOTICE).

`spec/ksef/contract_spec.rb` checks every request the gem makes against it (operations, parameters,
tokens, request schemas, response fields the gem reads, enums). The file name follows
`Ksef::API_VERSION`.

## Moving to a new API version

1. `bundle exec rake contract:drift` — compares this file with the documents TEST, DEMO and PROD
   publish now and lists the operations and schemas that changed.
2. Read the matching entries of `api-changelog.md` in CIRFMF/ksef-api.
3. Download the new document from TEST into `ksef-api-<version>.json`, delete the old one and set
   `Ksef::API_VERSION` to the new version.
4. Run `bundle exec rspec spec/ksef/contract_spec.rb` and adapt the gem until it passes — a new
   operation or parameter fails the coverage check until the gem supports it.
5. Confirm on live TEST: `bundle exec rake e2e:test`.
