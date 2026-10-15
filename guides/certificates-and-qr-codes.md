# Certificates and QR codes

## KSeF certificates

KSeF issues its own certificates of two types:

- **Authentication** — to sign in;
- **Offline** — to sign QR code II on invoices issued offline.

To get one, you send a certificate request (CSR) and download the certificate once KSeF has issued
it. You must be signed in with a certificate (XAdES) to do this.

```ruby
csr = Ksef::Crypto::Csr.generate_ecdsa(client.certificates.enrollment_data)   # needs an XAdES session
enrollment = client.certificates.enroll(certificate_name: "Server", certificate_type: "Offline",   # or "Authentication"
                                        csr: csr.csr_der_base64)
client.certificates.enrollment_status(enrollment["referenceNumber"])   # status.code 200 → certificateSerialNumber
client.certificates.retrieve(certificate_serial_numbers: [serial])     # Base64 DER; keep csr.private_key_pem
```

Keep the private key (`csr.private_key_pem`): KSeF returns only the certificate.

## QR codes

An invoice handed over outside KSeF (as a PDF or on paper) carries QR codes that link to KSeF, so
anyone can check it:

| Code | What it is | Label under it |
|---|---|---|
| CODE I (`online`) | a link to the invoice in KSeF | the KSeF number, or `OFFLINE` for an invoice issued offline |
| CODE II (`offline`) | for an invoice issued offline: a link signed with a KSeF Offline certificate | `CERTYFIKAT` |

Rendering the image needs the `rqrcode` gem.

```ruby
link = Ksef::Qr::VerificationLink.from_client(client)
code1 = link.online(seller_nip: "5555555555", invoice_xml: xml)   # the date is the invoice's P_1
code2 = link.offline(context_type: "Nip", context_value: "5555555555", seller_nip: "5555555555",
                     certificate_serial: serial, private_key: csr.private_key, invoice_xml: xml)
Ksef::Qr::Code.new(code1, label: ksef_number).as_svg   # label: the KSeF number or "OFFLINE"; "CERTYFIKAT" for CODE II
```

- **Images:** the SVG scales with CSS and keeps the 4-module quiet zone. `as_png` renders the bare
  code, `as_ascii` a preview in the terminal.
- **Without the XML:** pass `invoice_hash:` (the `invoiceHash` KSeF returns, Base64 or Base64URL)
  instead of `invoice_xml:`. CODE I then also needs `issue_date:` (the invoice's `P_1`).
- **`certificate_serial:`** is the 16 hex digits of `certificateSerialNumber` (or `certificate.serial`).
- **`context_type:`** is `"Nip"`, `"InternalId"`, `"NipVatUe"` or `"PeppolId"` (or `:nip`, … as in
  authentication).
- **CODE II's key** is the Offline certificate's: RSA of at least 2048 bits or EC P-256.
