# Configuration

The gem works with its defaults. Change them to pick a KSeF environment, set timeouts or turn on
logging — and read [Running in production](#running-in-production) before you deploy.

## Settings

Set them once, at startup:

```ruby
Ksef.configure do |c|
  c.environment = :demo
  c.timeout = 30
  c.logger = Logger.new($stdout)
end
```

| Option | Default | What it does |
|---|---|---|
| `environment` | `:test` | which KSeF to talk to: `:test`, `:demo` or `:prod` |
| `timeout` / `open_timeout` | `60` / `15` | seconds to wait for a response / for a connection |
| `max_retries` | `2` | how many times a failed request is repeated ([when](#retries)) |
| `max_retry_after` | `60` | KSeF may answer "too many requests, wait N seconds" (`Retry-After`). The gem waits up to this many seconds; a longer wait raises `Ksef::RateLimited`. `nil` — always wait |
| `adapter` | `:net_http_persistent` | the HTTP library (a Faraday adapter). The default keeps connections open between requests; `:net_http` does not |
| `proxy` | `ENV["KSEF_PROXY"]` | HTTP proxy |
| `logger` | `nil` (Rails: `Rails.logger`) | logs every request at `debug` (method, path, status, time), retries, `X-System-Warning` and polling — never tokens or keys |
| `ksef_features` | `[]` | KSeF feature flags (the `X-KSeF-Feature` header), e.g. `subject-identifier-validation` |
| `default_headers`, `prefer_problem_details`, `user_agent` | | extra headers, the error format, the User-Agent |
| `api_base_url_override`, `qr_base_url_override` | | other hosts, e.g. a mock server |

- Configure **before** you create clients: a client takes a copy of the settings when it is created.
- A value of the wrong type (`timeout: "60"`) raises `Ksef::ConfigurationError` right away.

### A client with different settings

```ruby
demo = Ksef::Client.new(config: Ksef.config.with(environment: :demo))
```

`with` copies the global settings and changes only what you pass. In Rails, the copy includes what
`config.ksef.*` and the initializer set. `Ksef::Configuration.new` starts from the defaults instead.

## Rails

`bin/rails g ksef:install` creates `config/initializers/ksef.rb`. It sets only the environment, from
the `KSEF_ENV` variable when it is set. Put other settings in `config/application.rb` or an
environment file:

```ruby
# config/application.rb or an environment file
config.ksef.timeout = 30
```

- `config.ksef` takes the same keys as `Ksef.configure`. A misspelled key stops the app from booting.
- The initializer runs after `config.ksef.*`, so what it sets wins.
- Set the KSeF environment explicitly. Don't derive it from `Rails.env`: staging often runs as
  production, and invoices sent to PROD are legally binding.

## Running in production

### One client per process

A client is thread-safe. It holds the open connection, the cache of the Ministry's public keys and
the CA store, so create **one per process and environment** and share it. For each company or job,
derive a client with its own token:

```ruby
KSEF_CLIENT = Ksef::Client.new                                  # once per process, after any fork
client = KSEF_CLIENT.with_access_token(result.access_token)     # or -> { manager.access_token }
```

- Don't set `client.access_token =` on the shared client — use `with_access_token`.
- Background jobs: build the client after the worker process starts and derive the job's client
  from it ([token refresh](authentication.md#refreshing-the-access-token)). Clients and sessions
  can't be serialized, so they can't be job arguments.
- A client created in every job keeps its own connection and CA store until garbage collection.
- Threads share the client's connections and wait 0.5 s for a free one. With many threads, make the
  pool at least as big as their number: `adapter: [:net_http_persistent, { pool_size: 5 }]`.
- `client.close` closes the open connections; the next request opens new ones.

### Retries

The gem repeats a failed request (up to `max_retries` times) only when that is safe:

| Failure | Repeated for |
|---|---|
| 429 Too Many Requests | every request — KSeF answers it before doing anything |
| 500, 502, 503, 504, connection errors (not TLS) | only reads (GET) and package uploads/downloads (presigned URLs), with backoff — a POST may already have done its work |
| a failure before anything was sent (a connect timeout, a busy connection pool) | every request |

### Calling KSeF from a web request

The defaults suit background jobs: a request may wait 60 s, a GET is retried twice, and a 429 wait
can last 60 s per retry. A web request shouldn't hang that long, so give controllers a client that
fails fast:

```ruby
WEB_KSEF = Ksef::Client.new(config: Ksef.config.with(timeout: 10, open_timeout: 5, max_retries: 0,
                                                     max_retry_after: 0))
```

### Good to know

- **Monitoring:** each HTTP attempt is published as `request.ksef` (ActiveSupport::Notifications)
  with `method`, `path` and `status`.
- **Secrets:** tokens and keys are hidden in `#inspect` and `pp` output.
- **Package transfers** go only to `https` URLs.
- **`enforce_xades_compliance!`** is not needed: KSeF checks XAdES signatures strictly everywhere.

<details>
<summary>Edge cases</summary>

- **Forking servers and job runners.** Create clients *after* the process forks. A client used both
  before and after a `fork` shares its open connection with the other process: its next request,
  GET or POST, can fail with `Ksef::NetworkError` for about 5 s, and a POST may or may not have been
  processed. A client that has to survive a fork needs `adapter: :net_http`.
- **Proxy password with `%`-encoded characters.** Use `adapter: :net_http`. The default adapter
  (faraday-net_http_persistent 2.3) fails on it with `URI::InvalidComponentError`.

</details>
