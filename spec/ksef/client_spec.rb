# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Client do
  let(:base) { ClientHelper::API_BASE }

  it "reads a callable access token on every request (e.g. a TokenManager)" do
    tokens = %w[first second]
    client = test_client(access_token: -> { tokens.shift })
    stub = stub_request(:get, "#{base}/limits/context").to_return(status: 200, body: "{}")

    client.limits.context
    client.limits.context

    %w[first second].each do |token|
      expect(a_request(:get, "#{base}/limits/context").with(headers: { "Authorization" => "Bearer #{token}" }))
        .to have_been_made
    end
    expect(stub).to have_been_requested.twice
  end

  it "with_access_token shares the connection and the key cache, without touching the original" do
    client = test_client(access_token: "tenant-a")
    other = client.with_access_token("tenant-b")

    expect(other.access_token).to eq("tenant-b")
    expect(client.access_token).to eq("tenant-a")
    expect(other.connection).to be(client.connection)
    expect(other.public_keys).to be(client.public_keys)
    expect(other.crypto).not_to be_nil
  end

  it "keeps the environment it was built with when the global configuration changes later" do
    Ksef.configure { |config| config.environment = :test }
    client = Ksef::Client.new
    Ksef.configure { |config| config.environment = :prod }

    expect(client.config.environment).to eq(:test)
    expect(client.config.qr_url).to include("qr-test")
  ensure
    Ksef.reset_config!
  end
end

RSpec.describe Ksef::Configuration do
  it "applies known options and rejects unknown ones (Rails `config.ksef.*`)" do
    config = described_class.new
    logger = Logger.new(nil)

    config.apply(environment: "demo", max_retries: 5, prefer_problem_details: false, "logger" => logger)

    expect(config.environment).to eq(:demo)
    expect(config.max_retries).to eq(5)
    expect(config.prefer_problem_details).to be(false)
    expect(config.logger).to be(logger)
    expect { config.apply(enviroment: :prod) }.to raise_error(Ksef::ConfigurationError, /enviroment/)
  end

  it "with copies the configuration for another environment, keeping the other options" do
    logger = Logger.new(nil)
    config = described_class.new.apply(timeout: 30, logger: logger, ksef_features: ["a"],
                                       default_headers: { "X-App" => "1" })
    demo = config.with(environment: :demo)

    expect([demo.environment, demo.timeout, demo.logger]).to eq([:demo, 30, logger])
    expect(demo.api_url).to start_with("https://api-demo.ksef.mf.gov.pl")
    demo.ksef_features << "b"
    demo.default_headers["X-Other"] = "2"
    expect([config.environment, config.ksef_features, config.default_headers]).to eq([:test, ["a"], { "X-App" => "1" }])
    expect { config.with(timout: 5) }.to raise_error(Ksef::ConfigurationError, /timout/)
  end

  it "refuses option values of the wrong type when they are set" do
    config = described_class.new

    { timeout: "60", open_timeout: 0, max_retries: "2", max_retry_after: -1 }.each do |name, value|
      expect { config.apply(name => value) }.to raise_error(Ksef::ConfigurationError, /#{name}/)
    end
    expect { config.apply(max_retry_after: nil, timeout: 1.5, max_retries: 0) }.not_to raise_error
  end

  it "keeps proxy credentials out of #inspect in every form Faraday accepts" do
    ["http://user:s3cret@proxy.local:3128", "user:s3cret@proxy.local:3128", "http://s3cret@proxy.local:3128",
     { uri: "http://proxy.local:3128", user: "user", password: "s3cret" }].each do |proxy|
      config = described_class.new.tap { |c| c.proxy = proxy }

      expect(config.inspect).to include("http://[REDACTED]@proxy.local:3128")
      expect(config.inspect).not_to include("s3cret")
    end
    expect(described_class.new.tap { |c| c.proxy = "http://proxy.local:3128" }.inspect)
      .to include('proxy="http://proxy.local:3128"')
  end

  it "reads the proxy from KSEF_PROXY" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("KSEF_PROXY", nil).and_return("http://proxy.local:3128")

    expect(described_class.new.proxy).to eq("http://proxy.local:3128")
  end
end

RSpec.describe Ksef::Polling do
  it "backs off between attempts, honours a server-suggested delay and returns the result" do
    attempts = [described_class.pending, described_class.pending(retry_after: 7), :done]
    allow(described_class).to receive(:sleep)

    result = described_class.run(interval: 1, backoff: 2, max_interval: 30, timeout: 60) { attempts.shift }

    expect(result).to eq(:done)
    expect(described_class).to have_received(:sleep).with(1.0).ordered
    expect(described_class).to have_received(:sleep).with(7.0).ordered
  end

  it "raises PollingTimeout with the last status once the time is up" do
    allow(described_class).to receive(:clock).and_return(0, 0, 10)
    allow(described_class).to receive(:sleep)

    expect { described_class.run(timeout: 5, interval: 1, description: "export X") { described_class.pending } }
      .to raise_error(Ksef::PollingTimeout, /export X/) { |error| expect(error.last_status).to eq("pending") }
  end
end
