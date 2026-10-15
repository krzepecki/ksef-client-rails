# Errors

Every error the gem raises inherits from `Ksef::Error`, network failures included. Rescue it to
catch everything.

## The ones you will meet most

| Error | What it means | What to do |
|---|---|---|
| `Ksef::InvoiceRejected` | KSeF rejected an invoice (`450` content, `440` duplicate) | the reason is in `e.body["status"]["details"]` |
| `Ksef::ReauthenticationRequired` | the access token can't be refreshed any more | sign in again |
| `Ksef::SessionUnavailable` | the session is under maintenance (`21184`) | continue in a new session |
| `Ksef::RateLimited` | too many requests | `#retry_after` says how many seconds to wait |
| `Ksef::NetworkError`, `Ksef::RequestTimeout` | a connection problem or timeout, after the retries | after sending an invoice: check the session's invoices before sending it again |
| `Ksef::SchemaValidationError` | the invoice XML is invalid | `#errors` says where |
| `Ksef::ConfigurationError` | invalid input, found before anything was sent | |
| `Ksef::AuthenticationFailed` | KSeF refused the sign-in (a `status.code` such as `450`, not an HTTP code) | |

## All errors

```text
Ksef::Error
├── ApiError                      KSeF answered with an error: #status, #codes (business codes), #trace_id, #body
│   ├── BadRequest                400
│   │   └── SessionUnavailable    21184: the session is under maintenance
│   ├── Unauthorized              401
│   ├── Forbidden                 403
│   ├── NotFound                  404
│   ├── Conflict                  409
│   ├── Gone                      410
│   ├── RateLimited               429: #retry_after
│   ├── ServerError               5xx
│   ├── InvoiceRejected           invoice status.code 400 or more (450, 440 duplicate…): #status nil, #body the invoice status
│   └── ReauthenticationRequired  sign in again: 21301, 21304 or a 401 from the token refresh
├── NetworkError                  a transport failure after the retries: #cause is the original error
│   └── RequestTimeout
├── AuthenticationFailed          an authentication status.code (e.g. 450 — not an HTTP code)
├── PollingTimeout                too long a wait
├── SchemaValidationError         invalid XML: #messages, #errors
├── BatchUploadError              a failed batch part upload or close: #reference_number, #ordinal_number
├── ResultTruncated               the 10,000-record query limit: #last_item
├── CryptoError                   a crypto problem
└── ConfigurationError            invalid input
```

- `ApiError` also covers a failed export (`#status` nil, the code in `#codes`) and a successful
  response that is not what the endpoint returns: not a JSON object, a required field missing, not an
  XML document.
- `ReauthenticationRequired`: `21301` — the sign-in does not allow a refresh (e.g. its KSeF token
  was revoked); `21304` — the sign-in does not exist (also from the sign-in status).
- A network error after the request went out (a timeout, a reset, a cut-off response) leaves the
  outcome unknown for a request that is not safe to repeat.
- Safe requests are retried before an error reaches you; a POST only after a 429, which KSeF answers
  before processing it ([Retries](configuration.md#retries)).
- KSeF has two error formats (legacy and RFC 7807); the gem reads both.
