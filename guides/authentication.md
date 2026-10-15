# Authentication

Before anything else, you sign in to KSeF on behalf of a company. You get two tokens: an **access
token** for API calls (valid for 15 minutes) and a **refresh token** to get new access tokens
without signing in again.

You can sign in with a [KSeF token](#with-a-ksef-token) or with a
[certificate](#with-a-certificate-xades). Both return a result with `access_token`, `refresh_token`
and `access_token_valid_until`.

## Who you act for: the context

The company you act for is the **context**. Usually it is a NIP; you pass it as `context:` when you
sign in:

```ruby
context = { nip: "5555555555" }   # or internal_id:, nip_vat_ue:, peppol_id:
```

- A NIP may be written with spaces, dashes or a `PL` prefix; the gem sends its 10 digits. The same
  goes for `seller_nip:` in QR links.
- An invalid context, subject type or `allowed_ips` raises `Ksef::ConfigurationError` before
  anything is sent.

## With a KSeF token

A KSeF token is a long secret generated in KSeF's web app for taxpayers:

```ruby
result = Ksef::Auth::Coordinator.new(client).authenticate_with_token(context: { nip: "5555555555" },
                                                                     token: ENV.fetch("KSEF_TOKEN"))
```

The gem encrypts the token with the Ministry's public key before sending it.

## With a certificate (XAdES)

You prove who you are by signing a one-time challenge with your certificate's private key:

1. The gem asks KSeF for a challenge.
2. It builds a small XML document with the challenge and the context, and signs it with your key (a
   XAdES signature).
3. KSeF checks the signature and that the certificate belongs to the company.
4. The gem waits until KSeF has finished and collects the tokens.

```ruby
cert = OpenSSL::X509::Certificate.new(File.binread("ksef.cert"))   # PEM or DER
key  = OpenSSL::PKey.read(File.binread("ksef.key"), ENV.fetch("KSEF_CERT_PASSWORD", ""))
# or from PKCS#12: p12 = OpenSSL::PKCS12.new(File.binread("seal.p12"), password); cert, key = p12.certificate, p12.key

result = Ksef::Auth::Coordinator.new(client).authenticate(
  context: { nip: "5555555555" },
  signer: Ksef::Xades::Signer.new(cert: cert, key: key),     # RSA or EC P-256
  subject_identifier_type: :certificate_subject,             # or :certificate_fingerprint
  verify_certificate_chain: false,                           # true adds an OCSP/CRL check
  allowed_ips: { addresses: ["203.0.113.7"] }                # optional; also ranges:, masks: (up to 10 each)
)
result.access_token # and result.refresh_token
```

**Which certificate works:**

- With `:certificate_subject` (the default), the certificate must name the company or the person:
  - a company seal: `organizationIdentifier` = `VATPL-<NIP>`;
  - a person: `serialNumber` = `TINPL-<NIP>` or `PNOPL-<PESEL>`.
- Any other certificate: use `:certificate_fingerprint`, once permissions are granted to its
  fingerprint in KSeF.
- Self-signed certificates work on TEST only ([try it](#trying-test-without-credentials)).

**Common problems:**

- **No key password?** Pass `""`, never `nil`. If the key turns out to be encrypted, `nil` makes
  OpenSSL ask for the password on the terminal.
- **Wrong key.** A key that doesn't match the certificate, or one KSeF refuses (RSA under 2048 bits,
  EC under 256), raises `Ksef::CryptoError` before sending. Otherwise KSeF would answer only with its
  unhelpful error `9105` (invalid signature).

**Signing elsewhere (HSM, qualified signature).** Any object with `#call(xml)` or `#sign(xml)` that
returns the signed XML can be the signer, e.g. `signer: ->(xml) { MyHsm.sign_xades(xml) }`. A bare
key (`OpenSSL::PKey`) is refused — wrap it in `Ksef::Xades::Signer`.

## Refreshing the access token

The access token expires after 15 minutes. `Ksef::TokenManager` gets a new one for you:

```ruby
manager = Ksef::TokenManager.new(client, access_token: result.access_token, refresh_token: result.refresh_token,
                                         access_token_valid_until: result.access_token_valid_until,
                                         on_refresh: ->(token, valid_until) { store(token, valid_until) })   # optional
client = client.with_access_token(-> { manager.access_token })
```

**How it works.** There is no background thread:

- On every request, the client asks the manager for the token. The manager only compares the clock
  with the token's expiry.
- When fewer than 60 seconds are left, the manager gets a new token from KSeF first. Only that one
  request takes a little longer.
- When many threads hit the expiry at once, one refreshes and the others wait for its token.
- An idle app refreshes nothing; its next request refreshes first. To refresh ahead of time, call
  `manager.access_token` from a periodic job, or `manager.force_refresh!` to refresh unconditionally.

**Saving the new token.** `on_refresh` receives each new token and its expiry, e.g. to store them
for other processes or jobs. It runs outside the manager's lock; if it raises, it runs again on the
next `access_token`.

**When you must sign in again.** `Ksef::ReauthenticationRequired` means the token can't be refreshed:
the refresh token expired or was revoked (KSeF answers 401), or KSeF refuses to refresh this
sign-in (`21301`, `21304`). Sign in again.

## Trying TEST without credentials

TEST accepts a self-signed company seal (`organizationIdentifier` `VATPL-<NIP>`) for any valid NIP,
so you can try everything without a real certificate.

<details>
<summary>Generate a random NIP and a self-signed seal, then sign in</summary>

```ruby
nip = loop do                                    # a random NIP with a valid check digit
  digits = [rand(1..9), *Array.new(8) { rand(10) }]
  check = Ksef::Nip::WEIGHTS.each_with_index.sum { |weight, i| weight * digits[i] } % 11
  candidate = (digits + [check]).join
  break candidate if check < 10 && Ksef::Nip.new(candidate).valid?
end
key = OpenSSL::PKey::RSA.new(2048)               # or OpenSSL::PKey::EC.generate("prime256v1")
cert = OpenSSL::X509::Certificate.new
cert.version = 2
cert.serial = OpenSSL::BN.rand(64)
cert.subject = cert.issuer = OpenSSL::X509::Name.new(
  [["CN", "Test seal"], ["O", "Test seal"], ["2.5.4.97", "VATPL-#{nip}", OpenSSL::ASN1::UTF8STRING], ["C", "PL"]]
)
cert.public_key = OpenSSL::PKey.read(key.public_to_der)
cert.not_before = Time.now - 300
cert.not_after = Time.now + (365 * 86_400)
cert.sign(key, OpenSSL::Digest.new("SHA256"))

client = Ksef::Client.new(config: Ksef.config.with(environment: :test))
result = Ksef::Auth::Coordinator.new(client).authenticate(context: { nip: nip },
                                                          signer: Ksef::Xades::Signer.new(cert: cert, key: key))
```

</details>

<details>
<summary>Edge cases</summary>

- **`21308`** (the credentials of a deceased person) is a plain `Ksef::BadRequest`: signing in again
  does not help.
- **IP restrictions** (`allowed_ips:`) are available only when you sign in with a certificate.

</details>
