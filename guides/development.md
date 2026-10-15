# Development

For working on the gem itself.

```bash
bundle exec rake                          # rspec (incl. the contract) + rubocop + XSD check of the sample invoice
bundle exec rake "xsd:outline[Faktura/Fa]"   # a form's field tree from the packaged schema
bundle exec rake contract:drift e2e:test oracle:all   # need network
```

## Verification

How we know the gem talks to KSeF correctly:

- **Contract** — on every `rspec` run. `spec/ksef/contract_spec.rb` checks each request the gem sends
  against KSeF's official API description (the 2.8.1 OpenAPI document in `spec/fixtures/openapi/`):
  - the operation, path, query (every value of a repeated parameter) and header parameters, tokens and
    JSON body;
  - every list, walked to its second page;
  - the response fields and enums the gem relies on.

  It also fails when an operation or parameter goes unused.
- **Live** — `rake e2e:test` runs every flow on KSeF TEST with a throwaway self-signed seal for a
  random NIP — no credentials needed — and revokes what it creates.
- **Cryptography** — `rake oracle:all` checks the gem's output with an independent Python
  implementation: the AES/RSA-OAEP output, the KSeF-token plaintext, the CSRs (RDN order and ASN.1
  types) and the XAdES signatures (digests, SignatureValue, SigningCertificate).

## Checking for KSeF API changes

The contract suite compares the gem with the saved API description, not with the servers. To see
whether KSeF has changed (changes reach TEST first):

```bash
bundle exec rake contract:drift   # TEST, DEMO, PROD vs. the fixture
bundle exec rake e2e:test         # every flow on live TEST
```

If something differs, follow [Moving to a new API version](../spec/fixtures/openapi/README.md#moving-to-a-new-api-version).
New invoice schemas are updated by hand ([schemas/README.md](../schemas/README.md)).
