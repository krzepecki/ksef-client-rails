# ksef-client-rails

A Ruby gem for **KSeF** (Krajowy System e-Faktur), the Polish government system for VAT invoices.
Your Ruby or Rails app can use it to send invoices to KSeF and to download the ones your company
received.

It supports every operation of KSeF API 2.0 (version 2.8.1). It works in plain Ruby; under Rails it
adds a generator and `config.ksef` settings.

## What you can do with it

- **Sign in** to KSeF on behalf of a company, with a KSeF token or a certificate
- **Send invoices**, one at a time or many in one package
- **Download invoices** you received or issued, and keep a local copy up to date
- **Build invoice XML** in Ruby and check it before sending
- **Make QR codes** that let anyone check the invoice in KSeF

## How KSeF works

1. **You sign in** as someone who acts for a company, identified by its tax number (NIP). You get an
   access token, valid for 15 minutes.
2. **You open a session** and send invoices in it. The gem encrypts each invoice for you.
3. **KSeF checks each invoice.** An accepted invoice gets a KSeF number and an official receipt, the
   UPO.
4. **Invoices other companies issue to you** land in KSeF too. You search for them and download them.

KSeF runs in three environments:

| Environment | What it is for |
|---|---|
| TEST | development; accepts self-signed certificates |
| DEMO | final checks before going live |
| PROD | real invoices — **legally binding** |

## Installation

Add to your Gemfile (Ruby 3.3 or newer):

```ruby
gem "ksef-client-rails", "~> 1.0"
gem "rqrcode"    # optional: only if you make QR codes
gem "minitar"    # optional: only if you use tar.gz packages
```

In Rails, run `bin/rails g ksef:install`. It creates `config/initializers/ksef.rb`.

## Quick start

### 0. Set up

```ruby
require "ksef"

Ksef.configure { |c| c.environment = :test }   # :test, :demo or :prod
client = Ksef::Client.new
nip = "5555555555"                             # the company you act for
```

### 1. Sign in

**With a KSeF token** — you generate it in KSeF's web app for taxpayers:

```ruby
auth = Ksef::Auth::Coordinator.new(client)
result = auth.authenticate_with_token(context: { nip: nip }, token: ENV.fetch("KSEF_TOKEN"))
```

**Or with a certificate** — a company seal or a personal certificate, as PEM or DER files:

```ruby
cert = OpenSSL::X509::Certificate.new(File.binread("ksef.cert"))
key  = OpenSSL::PKey.read(File.binread("ksef.key"), ENV.fetch("KSEF_CERT_PASSWORD", ""))
result = auth.authenticate(context: { nip: nip }, signer: Ksef::Xades::Signer.new(cert: cert, key: key))
```

Either way, give the access token to the client:

```ruby
client = client.with_access_token(result.access_token)
```

The token expires after 15 minutes. To have it refreshed for you, see
[refreshing the access token](guides/authentication.md#refreshing-the-access-token).

### 2. Send an invoice

The gem ships three sample invoices (also as XML in [`examples/`](examples)). Check the invoice
locally first, then send it in a session:

```ruby
invoice_xml = Ksef::Invoices::Sample.typical(seller_nip: nip, invoice_number: "FV/2026/10/1").to_xml
Ksef::Invoices::Validator.new.validate!(invoice_xml)   # raises if the XML is invalid

session = Ksef::Sessions::Online.open(client)
sent = session.send_invoice(invoice_xml)
session.close

upo = session.wait_for_upo(sent.reference_number)      # waits until KSeF accepts the invoice
ksef_number = client.sessions.invoice(session.reference_number, sent.reference_number)["ksefNumber"]
```

`upo` is the official receipt (XML). If KSeF rejects the invoice, `wait_for_upo` raises
`Ksef::InvoiceRejected` with the reason.

### 3. Download invoices you received

First search (you get a list of invoices without their content), then download each one:

```ruby
filters = {
  "subjectType" => "Subject2",                   # you are the buyer; "Subject1" — you are the seller
  "dateRange" => { "dateType" => "Invoicing", "from" => (Time.now - (30 * 86_400)).utc.iso8601 }
}
client.invoices.query_metadata(filters: filters, sort_order: "Desc").first(10).each do |meta|
  xml = client.invoices.get_by_ksef_number(meta["ksefNumber"])
  File.write("#{meta['ksefNumber']}.xml", xml)
end
```

## Guides

| I want to… | Guide |
|---|---|
| set timeouts and logging, use it in Rails or in background jobs | [Configuration](guides/configuration.md) |
| sign in, keep the token fresh, try TEST without credentials | [Authentication](guides/authentication.md) |
| build an invoice in Ruby or check its XML | [Invoice XML](guides/invoice-xml.md) |
| send many invoices, handle rejections | [Sending invoices](guides/sending-invoices.md) |
| search, download or sync invoices | [Receiving invoices](guides/receiving-invoices.md) |
| get a KSeF certificate or make QR codes | [Certificates and QR codes](guides/certificates-and-qr-codes.md) |
| manage tokens, permissions, limits | [Other resources](guides/other-resources.md) |
| know which errors to rescue | [Errors](guides/errors.md) |
| test my app without calling KSeF | [Testing your app](guides/testing.md) |
| work on the gem itself | [Development](guides/development.md) |

## Demo application

[`examples/ksef_demo`](examples/ksef_demo) is a small Rails app where you can click through every
feature on TEST, DEMO and PROD. Start it with `bundle install && bin/rails server` in its directory.
Run it only on your own machine: invoices it sends to PROD are legally binding.
More in [its README](examples/ksef_demo/README.md).

## Project status

Every request the gem sends is checked against the official KSeF API description on each test run,
and every flow works on live KSeF TEST ([how it is verified](guides/development.md#verification)).
Not exercised live: 5xx retries, `SessionUnavailable` and a token refresh refused with 401.

## License

MIT — see [`LICENSE.txt`](LICENSE.txt). The bundled XSD schemas and the OpenAPI fixture come from the
Ministry of Finance under MIT ([`NOTICE`](NOTICE)). Provided "as is", without warranty — check results
against KSeF before relying on them for tax obligations. Not affiliated with the Ministry of Finance.
