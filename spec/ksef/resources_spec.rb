# frozen_string_literal: true

require "spec_helper"

# Smoke tests for the resource wrappers: they confirm correct path building, pagination and token
# passing at the HTTP layer (WebMock).
RSpec.describe "Resource wrappers" do
  let(:client) { test_client(access_token: "acc") }
  let(:base) { ClientHelper::API_BASE }

  describe Ksef::Resources::Certificates do
    it "fetches certificate limits with the access token" do
      stub_request(:get, "#{base}/certificates/limits")
        .with(headers: { "Authorization" => "Bearer acc" })
        .to_return(status: 200, body: JSON.generate("canRequest" => true))
      expect(client.certificates.limits).to eq("canRequest" => true)
    end
  end

  describe Ksef::Resources::Sessions do
    it "returns the UPO as a UTF-8 string, not BINARY bytes" do
      upo = "<Potwierdzenie><NazwaPodmiotu>Spółka zażółć</NazwaPodmiotu></Potwierdzenie>"
      stub_request(:get, "#{base}/sessions/S/invoices/I/upo")
        .to_return(status: 200, body: upo.b, headers: { "Content-Type" => "application/xml" })

      result = client.sessions.invoice_upo("S", "I")
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to be_valid_encoding
      expect("UPO: #{result}").to include("zażółć")
    end

    it "lists sessions with the required sessionType" do
      stub = stub_request(:get, "#{base}/sessions")
             .with(query: { "sessionType" => "Batch", "pageSize" => "20" })
             .to_return(status: 200, body: JSON.generate("sessions" => [{ "referenceNumber" => "S-1" }]))

      expect(client.sessions.list(session_type: :batch).map { |s| s["referenceNumber"] }.to_a).to eq(["S-1"])
      expect(stub).to have_been_requested
    end

    it "rejects a session type outside the contract before enumeration starts" do
      expect { client.sessions.list(session_type: "interactive") }
        .to raise_error(Ksef::ConfigurationError, %r{Online/Batch})
      expect { client.sessions.list }.to raise_error(ArgumentError, /session_type/)
    end
  end

  describe Ksef::Resources::Limits do
    it "fetches context limits" do
      stub_request(:get, "#{base}/limits/context").to_return(status: 200, body: JSON.generate("session" => {}))
      expect(client.limits.context).to eq("session" => {})
    end
  end

  describe Ksef::Resources::Permissions do
    it "iterates a query with offset pagination (pageOffset/pageSize + hasMore)" do
      stub_request(:post, "#{base}/permissions/query/persons/grants")
        .with(query: { "pageOffset" => "0", "pageSize" => "10" })
        .to_return(status: 200, body: JSON.generate("permissions" => [{ "id" => 1 }], "hasMore" => true))
      stub_request(:post, "#{base}/permissions/query/persons/grants")
        .with(query: { "pageOffset" => "1", "pageSize" => "10" })
        .to_return(status: 200, body: JSON.generate("permissions" => [{ "id" => 2 }], "hasMore" => false))

      result = client.permissions.query_persons(body: { "queryType" => "PermissionsInCurrentContext" }).to_a
      expect(result.map { |r| r["id"] }).to eq([1, 2])
    end
  end

  describe Ksef::Resources::Invoices do
    let(:filters) { { "subjectType" => "Subject1", "dateRange" => { "dateType" => "Issue", "from" => "2026-01-01" } } }

    it "sends sortOrder together with the offset pagination parameters" do
      stub_request(:post, "#{base}/invoices/query/metadata")
        .with(query: { "pageOffset" => "0", "pageSize" => "10", "sortOrder" => "Desc" }, body: JSON.generate(filters))
        .to_return(status: 200, body: JSON.generate("invoices" => [{ "ksefNumber" => "b" }], "hasMore" => false))

      result = client.invoices.query_metadata(filters: filters, page_size: 10, sort_order: "Desc").to_a
      expect(result.map { |r| r["ksefNumber"] }).to eq(["b"])
    end

    it "omits sortOrder when not given (the API default is Asc)" do
      stub_request(:post, "#{base}/invoices/query/metadata")
        .with(query: { "pageOffset" => "0", "pageSize" => "10" })
        .to_return(status: 200, body: JSON.generate("invoices" => [], "hasMore" => false))

      expect(client.invoices.query_metadata(filters: filters, page_size: 10).to_a).to eq([])
    end

    it "rejects a sort order outside the contract" do
      expect { client.invoices.query_metadata_page(filters: filters, sort_order: "descending") }
        .to raise_error(Ksef::ConfigurationError, %r{Asc/Desc})
    end

    it "rejects an invalid sort order before enumeration starts (the enumerator is lazy)" do
      expect { client.invoices.query_metadata(filters: filters, sort_order: "descending") }
        .to raise_error(Ksef::ConfigurationError, %r{Asc/Desc})
    end

    it "asks for the largest page by default and raises ResultTruncated at the 10,000-record limit" do
      stub = stub_request(:post, "#{base}/invoices/query/metadata")
             .with(query: { "pageOffset" => "0", "pageSize" => "250" })
             .to_return(status: 200, body: JSON.generate("invoices" => [{ "ksefNumber" => "last" }],
                                                         "hasMore" => true, "isTruncated" => true))

      expect { client.invoices.query_metadata(filters: filters).to_a }
        .to raise_error(Ksef::ResultTruncated) { |error| expect(error.last_item).to eq("ksefNumber" => "last") }
      expect(stub).to have_been_requested.once
    end
  end

  describe "path segments" do
    it "refuses a blank, nil, '.' or '..' segment without sending anything" do
      [nil, "", " ", ".", ".."].each do |value|
        expect { client.sessions.status(value) }.to raise_error(Ksef::ConfigurationError, /path segment/)
      end
      expect(a_request(:any, /#{Regexp.escape(base)}/)).not_to have_been_made
    end

    it "percent-encodes a segment, so it cannot change the route" do
      stub = stub_request(:get, "#{base}/sessions/a%2Fb%3Fc%23d").to_return(status: 200, body: '{"status":{}}')

      client.sessions.status("a/b?c#d")
      expect(stub).to have_been_requested
    end
  end

  describe Ksef::Resources::Auth do
    it "revokes the current session with the token it is given, not the client's" do
      stub = stub_request(:delete, "#{base}/auth/sessions/current")
             .with(headers: { "Authorization" => "Bearer refresh-tok" }).to_return(status: 204)

      client.auth.revoke_current_session(token: "refresh-tok")
      expect(stub).to have_been_requested
    end
  end

  describe Ksef::Resources::Tokens do
    it "iterates the token list with continuation pagination (x-continuation-token header)" do
      stub_request(:get, "#{base}/tokens")
        .with(query: hash_including("pageSize" => "20")) { |req| !req.headers.key?("X-Continuation-Token") }
        .to_return(status: 200, body: JSON.generate("tokens" => [{ "n" => "a" }], "continuationToken" => "c1"))
      stub_request(:get, "#{base}/tokens")
        .with(query: hash_including("pageSize" => "20"), headers: { "x-continuation-token" => "c1" })
        .to_return(status: 200, body: JSON.generate("tokens" => [{ "n" => "b" }], "continuationToken" => nil))

      expect(client.tokens.list.to_a.map { |t| t["n"] }).to eq(%w[a b])
    end
  end

  describe Ksef::Resources::TestData do
    it "refuses /testdata calls on the production environment without sending them" do
      prod = test_client(config: Ksef::Configuration.new(environment: :prod))

      expect { prod.test_data.create_subject(body: {}) }.to raise_error(Ksef::ConfigurationError, /production/)
      expect { prod.test_data.reset_rate_limits }.to raise_error(Ksef::ConfigurationError, /production/)
      expect(a_request(:any, /testdata/)).not_to have_been_made
    end

    it "refuses /testdata calls that would reach the production host under another label" do
      override = Ksef::Configuration.new(environment: :test)
      override.api_base_url_override = Ksef::Environments::PROD.api_base_url
      custom = Ksef::Environments::Environment.new(**Ksef::Environments::PROD.to_h, key: :mine)

      [override, Ksef::Configuration.new(environment: custom)].each do |config|
        expect { test_client(config: config).test_data.reset_rate_limits }
          .to raise_error(Ksef::ConfigurationError, /production/)
      end
      expect(a_request(:any, /testdata/)).not_to have_been_made
    end

    it "calls /testdata on TEST" do
      stub = stub_request(:post, "#{base}/testdata/subject").to_return(status: 200, body: "")

      client.test_data.create_subject(body: { "subjectNip" => "5555555555" })
      expect(stub).to have_been_requested
    end
  end
end
