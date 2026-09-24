# XSD schemas (local copy, packaged into the gem)

A copy of the official Ministry of Finance schemas. We keep them in the repository and ship them
with the gem (`spec.files`) so that `Ksef::Invoices::Validator` works **fully offline** — without
network access and without downloading from `crd.gov.pl`.

```
schemas/
├── FA/schemat_FA(2)_v1-0E.xsd        # FA(2) — TEST environment only
├── FA/schemat_FA(3)_v1-0E.xsd        # FA(3) — the default form
├── RR/schemat_FA_RR(1)_v1-1E.xsd     # FA_RR(1) — flat-rate farmers
└── bazowe/                           # types shared by all three forms
    ├── StrukturyDanych_v10-0E.xsd
    ├── ElementarneTypyDanych_v10-0E.xsd
    └── KodyKrajow_v10-0E.xsd
```

Source: the [`ksef-api`](https://github.com/CIRFMF/ksef-api) repository (`faktury/schemy/FA/`,
`faktury/schemy/RR/`, `faktury/schemy/FA/bazowe/`); the forms are published on crd.gov.pl — FA(3)
<https://crd.gov.pl/wzor/2025/06/25/13775/>, FA(2) <https://crd.gov.pl/wzor/2023/06/29/12648/>,
FA_RR(1) <https://crd.gov.pl/wzor/2026/03/06/14189/>.
Copyright (c) 2025 Ministerstwo Finansów, distributed under the MIT licence — the full notice is
in [`NOTICE`](../NOTICE).

**PEF (UBL) is deliberately not copied here** — it is a separate, much larger schema set; the
validator raises `Ksef::ConfigurationError` for it.

File names are kept exactly as published, including the Polish directory name `bazowe`, so that
diffing against a new release of the official schemas stays trivial.

## The only modification to the originals

In each of the three root schemas, the `schemaLocation` of the `DefinicjeTypy` import is a relative
path to the shared directory. The originals point it at an HTTP address on `crd.gov.pl`, which makes
validation try to fetch the schema over the network (libxml refuses: "Attempt to load network
entity"):

```diff
-schemaLocation="http://crd.gov.pl/xml/schematy/.../StrukturyDanych_v10-0E.xsd"
+schemaLocation="../bazowe/StrukturyDanych_v10-0E.xsd"
```

The `bazowe/*.xsd` files are byte-for-byte identical to the originals (they already reference each
other relatively). The schema content — types, cardinalities, enumerations — is untouched.

## Updating to a new form version

1. Copy the new files from `ksef-api` into the structure above.
2. Repeat the `schemaLocation` substitution **in every root schema** (see the diff above).
3. If a file name changes (e.g. `v1-1E`), update the `Ksef::Invoices::Validator::SCHEMAS` map and
   the `Ksef::FormCode` constants.
4. Run `rake xsd:validate` — `examples/fa3_*.xml` must pass; `rspec` covers
   `spec/ksef/validator_spec.rb`.
