# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::TokenManager do
  let(:base) { ClientHelper::API_BASE }
  let(:client) { test_client }

  it "returns the current token while it is still valid (no refresh)" do
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now + 3600).iso8601)
    expect(manager.access_token).to eq("acc-1")
    expect(a_request(:post, "#{base}/auth/token/refresh")).not_to have_been_made
  end

  it "refreshes the token before expiry (honouring the skew margin)" do
    stub_request(:post, "#{base}/auth/token/refresh")
      .with(headers: { "Authorization" => "Bearer ref-1" })
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-2",
                                                                     "validUntil" => (Time.now + 3600).iso8601 }))

    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now - 1).iso8601)
    expect(manager.access_token).to eq("acc-2")
  end

  def jwt(exp)
    segment = ->(data) { Base64.urlsafe_encode64(JSON.generate(data), padding: false) }
    "#{segment.call('alg' => 'none')}.#{segment.call('exp' => exp.to_i)}.signature"
  end

  it "reads the expiry from the token's JWT exp claim when access_token_valid_until is not given" do
    stub_request(:post, "#{base}/auth/token/refresh")
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-2" }))
    valid_token = jwt(Time.now + 3600)
    fresh = described_class.new(client, access_token: valid_token, refresh_token: "ref-1")
    expired = described_class.new(client, access_token: jwt(Time.now - 1), refresh_token: "ref-1")

    expect(fresh.access_token).to eq(valid_token)
    expect(a_request(:post, "#{base}/auth/token/refresh")).not_to have_been_made
    expect(expired.access_token).to eq("acc-2")
  end

  it "accepts a DateTime as access_token_valid_until" do
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: DateTime.now + 1)
    expect(manager.access_token).to eq("acc-1")
    expect(a_request(:post, "#{base}/auth/token/refresh")).not_to have_been_made
  end

  it "reports each refresh to on_refresh and exposes the new expiry" do
    valid_until = Time.now + 900
    stub_request(:post, "#{base}/auth/token/refresh")
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-2",
                                                                     "validUntil" => valid_until.iso8601 }))
    refreshes = []
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now - 1).iso8601,
                                          on_refresh: ->(token, expiry) { refreshes << [token, expiry] })

    expect(manager.access_token).to eq("acc-2")
    expect(refreshes).to eq([["acc-2", Time.iso8601(valid_until.iso8601)]])
    expect(manager.access_token_valid_until).to eq(Time.iso8601(valid_until.iso8601))
  end

  it "uses a refreshed token that expires within the skew until it expires (skew > token lifetime)" do
    stub_request(:post, "#{base}/auth/token/refresh")
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-2",
                                                                     "validUntil" => (Time.now + 900).iso8601 }))
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now + 900).iso8601, skew: 1200)

    5.times { expect(manager.access_token).to eq("acc-2") }
    expect(a_request(:post, "#{base}/auth/token/refresh")).to have_been_made.once
  end

  it "force_refresh! always fetches a new token" do
    stub_request(:post, "#{base}/auth/token/refresh")
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-3", "validUntil" => nil }))
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now + 9999).iso8601)
    expect(manager.force_refresh!).to eq("acc-3")
  end

  it "runs on_refresh outside its lock, so the callback may use the manager" do
    stub_request(:post, "#{base}/auth/token/refresh")
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-2" }))
    seen = []
    manager = nil
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now - 1).iso8601,
                                          on_refresh: ->(token, _until) { seen << [token, manager.access_token] })

    expect(manager.access_token).to eq("acc-2")
    expect(seen).to eq([%w[acc-2 acc-2]])
  end

  it "calls a failed on_refresh again on the next access, without refreshing twice" do
    stub_request(:post, "#{base}/auth/token/refresh")
      .to_return(status: 200, body: JSON.generate("accessToken" => { "token" => "acc-2",
                                                                     "validUntil" => (Time.now + 3600).iso8601 }))
    calls = 0
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now - 1).iso8601,
                                          on_refresh: lambda { |_token, _until|
                                            calls += 1
                                            raise "store down" if calls == 1
                                          })

    expect { manager.access_token }.to raise_error(RuntimeError, "store down")
    expect(manager.access_token).to eq("acc-2")
    expect(manager.access_token).to eq("acc-2")
    expect(calls).to eq(2)
    expect(a_request(:post, "#{base}/auth/token/refresh")).to have_been_made.once
  end

  it "keeps the current token when the refresh response has none" do
    stub_request(:post, "#{base}/auth/token/refresh").to_return(status: 200, body: JSON.generate("accessToken" => {}))
    stored = []
    manager = described_class.new(client, access_token: "acc-1", refresh_token: "ref-1",
                                          access_token_valid_until: (Time.now - 1).iso8601,
                                          on_refresh: ->(token, _until) { stored << token })

    expect { manager.access_token }.to raise_error(Ksef::ApiError, /lacks accessToken.token/)
    expect(stored).to be_empty
  end
end
