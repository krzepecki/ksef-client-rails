# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Http::Connection do
  let(:config) { Ksef::Configuration.new(environment: :test) }
  subject(:connection) { described_class.new(config: config) }

  let(:base) { ClientHelper::API_BASE }

  it "attaches the Authorization Bearer header and parses JSON" do
    stub = stub_request(:get, "#{base}/limits/context")
           .with(headers: { "Authorization" => "Bearer tok-1" })
           .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })
    response = connection.get("/limits/context", bearer: "tok-1")
    expect(response.body).to eq("ok" => true)
    expect(stub).to have_been_requested
  end

  it "sends the default X-Error-Format: problem-details header" do
    stub = stub_request(:get, "#{base}/rate-limits")
           .with(headers: { "X-Error-Format" => "problem-details" })
           .to_return(status: 200, body: "{}")
    connection.get("/rate-limits")
    expect(stub).to have_been_requested
  end

  it "raises a typed exception on an HTTP error" do
    stub_request(:get, "#{base}/x").to_return(
      status: 403, body: '{"title":"Forbidden"}', headers: { "Content-Type" => "application/json" }
    )
    expect { connection.get("/x") }.to raise_error(Ksef::Forbidden)
  end

  it "retries a 429 honouring Retry-After, then succeeds" do
    config.max_retries = 1
    allow(connection).to receive(:sleep) # do not actually wait in the test
    stub_request(:get, "#{base}/y")
      .to_return({ status: 429, headers: { "Retry-After" => "0" } },
                 { status: 200, body: '{"done":true}' })
    expect(connection.get("/y").body).to eq("done" => true)
  end

  it "logs X-System-Warning" do
    logger = instance_double(Logger)
    config.logger = logger
    allow(logger).to receive(:debug)
    expect(logger).to receive(:warn).with(/X-System-Warning: maintenance/)
    stub_request(:get, "#{base}/z").to_return(status: 200, body: "{}",
                                              headers: { "X-System-Warning" => "maintenance" })
    connection.get("/z")
  end

  it "logs every attempt at debug level and publishes it as request.ksef, without the query string" do
    io = StringIO.new
    config.logger = Logger.new(io)
    events = []
    notifications = Module.new do
      define_singleton_method(:instrument) do |name, payload, &block|
        result = block.call
        events << [name, payload.dup]
        result
      end
    end
    stub_const("ActiveSupport::Notifications", notifications)
    stub_request(:get, "#{base}/invoices/query?secret=1").to_return(status: 404, body: "{}")

    expect { connection.get("/invoices/query?secret=1") }.to raise_error(Ksef::NotFound)
    expect(io.string).to match(%r{DEBUG -- : \[ksef\] GET invoices/query -> 404 \(\d+ ms\)})
    expect(events).to eq([["request.ksef", { method: "GET", path: "invoices/query", status: 404 }]])
    expect(io.string).not_to include("secret")
  end

  it "returns raw bytes when raw: true" do
    stub_request(:get, "#{base}/raw").to_return(status: 200, body: "<xml/>")
    expect(connection.get("/raw", raw: true).raw_body).to eq("<xml/>")
  end

  it "does not sleep through a Retry-After above max_retry_after — raises RateLimited instead" do
    config.max_retries = 3
    config.max_retry_after = 60
    expect(connection).not_to receive(:sleep)
    stub = stub_request(:get, "#{base}/slow").to_return(status: 429, headers: { "Retry-After" => "86400" })
    expect { connection.get("/slow") }.to raise_error(Ksef::RateLimited) { |e| expect(e.retry_after).to eq(86_400) }
    expect(stub).to have_been_requested.once
  end

  it "uses the configured Faraday adapter for both the API and presigned connections" do
    config.adapter = :net_http
    api = connection.send(:build_faraday)
    presigned = connection.send(:presigned_faraday)
    expect([api, presigned].map { |f| f.builder.adapter.klass }).to all(eq(Faraday::Adapter::NetHttp))
  end

  it "uses the keep-alive adapter by default" do
    expect(config.adapter).to eq(:net_http_persistent)
    expect(connection.send(:build_faraday).builder.adapter.klass).to eq(Faraday::Adapter::NetHttpPersistent)
  end

  it "sends array query parameters as repeated keys, as the contract defines them" do
    stubs = Faraday::Adapter::Test::Stubs.new
    query = nil
    stubs.get(%r{/v2/tokens\z}) do |env|
      query = env.url.query
      [200, {}, '{"tokens":[]}']
    end
    config.adapter = [:test, stubs]

    test_client(access_token: "acc", config: config).tokens.list(status: %w[Active Pending]).to_a

    expect(query.split("&")).to include("status=Active", "status=Pending")
    expect(query).not_to include("%5B%5D") # not status[]=…
  end

  describe "retries" do
    before { allow(connection).to receive(:sleep) }

    it "retries an idempotent GET on 502/503/504 with exponential backoff" do
      stub = stub_request(:get, "#{base}/status")
             .to_return({ status: 503 }, { status: 502 }, { status: 200, body: '{"ok":true}' })

      expect(connection.get("/status").body).to eq("ok" => true)
      expect(stub).to have_been_requested.times(3)
      expect(connection).to have_received(:sleep).with(0.5).ordered
      expect(connection).to have_received(:sleep).with(1.0).ordered
    end

    it "does not retry a POST on 5xx — it may have been processed" do
      stub = stub_request(:post, "#{base}/sessions/online").to_return(status: 503)

      expect { connection.post("/sessions/online", json: {}) }.to raise_error(Ksef::ServerError)
      expect(stub).to have_been_requested.once
    end

    it "gives up after max_retries and raises the last error" do
      stub = stub_request(:get, "#{base}/down").to_return(status: 503)

      expect { connection.get("/down") }.to raise_error(Ksef::ServerError)
      expect(stub).to have_been_requested.times(config.max_retries + 1)
    end

    it "retries a timed-out GET, then raises Ksef::RequestTimeout with the Faraday error as its cause" do
      stub = stub_request(:get, "#{base}/slow").to_raise(Net::ReadTimeout)

      expect { connection.get("/slow") }.to raise_error(Ksef::RequestTimeout, /GET slow/) { |error|
        expect(error).to be_a(Ksef::NetworkError)
        expect(error.cause).to be_a(Faraday::TimeoutError)
      }
      expect(stub).to have_been_requested.times(config.max_retries + 1)
    end

    it "does not retry a timed-out POST — the outcome is unknown" do
      stub = stub_request(:post, "#{base}/sessions/online/S/invoices").to_raise(Net::ReadTimeout)

      expect { connection.post("/sessions/online/S/invoices", json: {}) }.to raise_error(Ksef::RequestTimeout)
      expect(stub).to have_been_requested.once
    end

    it "retries a POST that never left the process (connect or pool checkout timeout) as a NetworkError" do
      require "connection_pool"
      stub_request(:post, "#{base}/a").to_raise(Net::OpenTimeout).then.to_return(status: 200, body: "{}")
      pool = stub_request(:post, "#{base}/b").to_raise(ConnectionPool::TimeoutError)

      expect(connection.post("/a", json: {}).status).to eq(200)
      expect { connection.post("/b", json: {}) }.to raise_error(Ksef::NetworkError) { |error|
        expect(error).not_to be_a(Ksef::RequestTimeout)
      }
      expect(pool).to have_been_requested.times(config.max_retries + 1)
    end

    it "retries a GET whose reused TLS connection was dropped without close_notify, but not a POST" do
      eof = OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading")
      stub_request(:get, "#{base}/eof").to_raise(eof).then.to_return(status: 200, body: "{}")
      post = stub_request(:post, "#{base}/eof").to_raise(eof)

      expect(connection.get("/eof").status).to eq(200)
      expect { connection.post("/eof", json: {}) }.to raise_error(Ksef::NetworkError)
      expect(post).to have_been_requested.once
    end

    it "reads a callable token again for a retry after a 429" do
      tokens = %w[old new]
      seen = []
      stub_request(:get, "#{base}/z").to_return do |request|
        seen << request.headers["Authorization"]
        seen.size == 1 ? { status: 429, headers: { "Retry-After" => "0" } } : { status: 200, body: "{}" }
      end

      connection.get("/z", bearer: -> { tokens.shift })
      expect(seen).to eq(["Bearer old", "Bearer new"])
    end

    it "treats a body shorter than its Content-Length as a dropped connection" do
      stub_request(:get, "#{base}/cut").to_return(status: 200, body: '{"a":', headers: { "Content-Length" => "40" })
                                       .then.to_return(status: 200, body: "{}")
      post = stub_request(:post, "#{base}/tokens")
             .to_return(status: 200, body: '{"token":"SECRET', headers: { "Content-Length" => "80" })

      expect(connection.get("/cut").status).to eq(200)
      expect { connection.post("/tokens", json: {}) }.to raise_error(Ksef::NetworkError, /cut short/) { |error|
        expect(error.message).not_to include("SECRET")
      }
      expect(post).to have_been_requested.once
    end

    it "recovers from a refused connection on GET and never retries a TLS failure" do
      stub_request(:get, "#{base}/flaky").to_raise(Errno::ECONNREFUSED).then.to_return(status: 200, body: "{}")
      tls = stub_request(:get, "#{base}/tls").to_raise(OpenSSL::SSL::SSLError)

      expect(connection.get("/flaky").status).to eq(200)
      expect { connection.get("/tls") }.to raise_error(Ksef::NetworkError) { |e| expect(e.cause).to be_a(Faraday::SSLError) }
      expect(tls).to have_been_requested.once
    end

    it "maps transport failures Faraday leaves unwrapped to Ksef::NetworkError, retrying only a GET" do
      down = stub_request(:get, "#{base}/down-host").to_raise(Errno::EHOSTDOWN)
      blocked = stub_request(:post, "#{base}/blocked").to_raise(Errno::EPERM)

      expect { connection.get("/down-host") }.to raise_error(Ksef::NetworkError, /EHOSTDOWN|host down/i)
      expect(down).to have_been_requested.times(config.max_retries + 1)
      expect { connection.post("/blocked", json: {}) }.to raise_error(Ksef::NetworkError)
      expect(blocked).to have_been_requested.once
    end

    it "treats a negative Retry-After as no wait, and max_retry_after = nil as no cap" do
      config.max_retry_after = nil
      stub_request(:get, "#{base}/busy")
        .to_return({ status: 429, headers: { "Retry-After" => "-5" } },
                   { status: 429, headers: { "Retry-After" => "7200" } },
                   { status: 200, body: "{}" })

      expect(connection.get("/busy").status).to eq(200)
      expect(connection).to have_received(:sleep).with(0).ordered
      expect(connection).to have_received(:sleep).with(7200).ordered
    end

    it "retries a presigned upload (PUT addresses one blob) on 503" do
      stub = stub_request(:put, "https://blob.example/part1").to_return({ status: 503 }, { status: 201 })

      expect(connection.presigned_transfer("PUT", "https://blob.example/part1", body: "x").status).to eq(201)
      expect(stub).to have_been_requested.twice
    end

    it "keeps the presigned URL (it carries a signature) out of error messages" do
      stub_request(:get, "https://blob.example/part1?sig=SECRET").to_raise(Net::ReadTimeout)

      expect { connection.presigned_transfer("GET", "https://blob.example/part1?sig=SECRET") }
        .to raise_error(Ksef::RequestTimeout) { |error| expect(error.message).not_to include("SECRET") }
    end
  end

  it "raises on a 2xx body that is not JSON (a proxy or WAF page) instead of returning it as data" do
    page = "<html><body>Request blocked by gateway #{'x' * 400}</body></html>".b
    stub_request(:get, "#{base}/tokens").to_return(status: 200, body: page, headers: { "Content-Type" => "text/html" })

    expect { connection.get("/tokens") }.to raise_error(Ksef::ApiError) { |error|
      expect(error.status).to eq(200)
      expect(error.message).to include("non-JSON response (text/html)", "Request blocked by gateway")
      expect(error.message.encoding).to eq(Encoding::UTF_8)
      expect(error.body.length).to be <= 301
    }
  end

  it "does not quote a 2xx JSON-typed body that fails to parse — it may carry a token" do
    stub_request(:post, "#{base}/tokens").to_return(status: 200, body: '{"token":"SECRET"',
                                                    headers: { "Content-Type" => "application/json" })

    expect { connection.post("/tokens", json: {}) }.to raise_error(Ksef::ApiError) { |error|
      expect(error.message).to include("application/json response of 17 bytes")
      expect(error.message).not_to include("SECRET")
      expect(error.body).to be_nil
    }
  end

  it "refuses a token with a line break without echoing it, and drops surrounding whitespace" do
    stub = stub_request(:get, "#{base}/t").with(headers: { "Authorization" => "Bearer tok" }).to_return(body: "{}")

    connection.get("/t", bearer: "tok\n")
    expect(stub).to have_been_requested
    expect { connection.get("/t", bearer: "QWE\r\nRTY") }.to raise_error(Ksef::ConfigurationError) { |error|
      expect(error.message).not_to include("QWE")
    }
  end

  it "sends no Authorization with auth: false" do
    stub = stub_request(:get, "#{base}/anon").to_return(body: "{}")

    connection.get("/anon", bearer: "tok", auth: false)
    expect(stub.with { |request| !request.headers.key?("Authorization") }).to have_been_requested
  end

  describe "raw XML downloads" do
    let(:xml) { "<UPO>zażółć</UPO>".b }
    let(:hash) { Base64.strict_encode64(Digest::SHA256.digest(xml)) }

    it "refuses a 2xx HTML page or an empty body instead of returning it as the document" do
      stub_request(:get, "#{base}/doc").to_return(
        { status: 200, body: "<!DOCTYPE html><html>maintenance</html>", headers: { "Content-Type" => "text/html" } },
        { status: 200, body: "" }
      )

      2.times do
        expect { connection.get("/doc", raw: :xml) }.to raise_error(Ksef::ApiError, /non-XML response/)
      end
    end

    it "checks the document against x-ms-meta-hash" do
      client = test_client(access_token: "acc")
      stub_request(:get, %r{/invoices/ksef/1\z})
        .to_return({ status: 200, body: xml, headers: { "x-ms-meta-hash" => hash } },
                   { status: 200, body: xml, headers: { "x-ms-meta-hash" => Base64.strict_encode64("x" * 32) } })

      expect(client.invoices.get_by_ksef_number("1")).to eq("<UPO>zażółć</UPO>")
      expect { client.invoices.get_by_ksef_number("1") }.to raise_error(Ksef::ApiError, /x-ms-meta-hash/)
    end
  end

  it "shares one CA store between connections and closes its keep-alive connections" do
    other = described_class.new(config: config)
    stores = [connection, other].map { |c| c.instance_variable_get(:@faraday).ssl.cert_store }

    expect(stores.uniq).to eq([described_class.default_cert_store])
    stub_request(:get, "#{base}/rate-limits").to_return(body: "{}")
    connection.get("/rate-limits")
    connection.close
    expect(connection.get("/rate-limits").status).to eq(200)
  end

  it "keeps the proxy password out of #inspect" do
    config.proxy = "http://user:s3cret@proxy.local:3128"

    expect(connection.inspect).not_to include("s3cret")
    expect(config.inspect).to include("http://[REDACTED]@proxy.local:3128")
    expect(config.inspect).not_to include("s3cret")
  end

  describe "#presigned_transfer" do
    it "refuses a non-https presigned URL without sending anything" do
      stub = stub_request(:put, "http://blob.example/part1")
      expect { connection.presigned_transfer("PUT", "http://blob.example/part1", body: "x") }
        .to raise_error(Ksef::ConfigurationError, /not https/)
      expect(stub).not_to have_been_requested
    end

    it "sends an upper-case https URL normalized, and refuses one without a host" do
      stub = stub_request(:put, "https://blob.example/part1").to_return(status: 201)

      connection.presigned_transfer("PUT", "HTTPS://BLOB.example/part1", body: "x")
      expect(stub).to have_been_requested
      expect { connection.presigned_transfer("PUT", "https:blob.example/part1") }
        .to raise_error(Ksef::ConfigurationError, /not https/)
    end

    it "refuses an unparsable presigned URL" do
      expect { connection.presigned_transfer("PUT", "https://blob.example/a b") }
        .to raise_error(Ksef::ConfigurationError, /invalid URL/)
    end
  end
end
