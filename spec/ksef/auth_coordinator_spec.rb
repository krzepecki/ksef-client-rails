# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Auth::Coordinator do
  let(:client) { test_client }
  subject(:coordinator) { described_class.new(client) }
  let(:base) { ClientHelper::API_BASE }

  let(:challenge_body) do
    { "challenge" => "20250604-CR-461EA5B000-537A6BA15D-D7", "timestamp" => Time.now.iso8601,
      "timestampMs" => 1_717_500_000_000 }
  end
  let(:init_body) do
    { "referenceNumber" => "REF-0001",
      "authenticationToken" => { "token" => "auth-tok", "validUntil" => Time.now.iso8601 } }
  end
  let(:tokens_body) do
    { "accessToken" => { "token" => "access-tok", "validUntil" => (Time.now + 3600).iso8601 },
      "refreshToken" => { "token" => "refresh-tok", "validUntil" => (Time.now + 86_400).iso8601 } }
  end

  def stub_flow(status_sequence)
    stub_request(:post, "#{base}/auth/challenge").to_return(status: 200, body: JSON.generate(challenge_body))
    stub_request(:post, "#{base}/auth/xades-signature")
      .with(query: hash_including("verifyCertificateChain" => "false"))
      .to_return(status: 202, body: JSON.generate(init_body))
    stub_request(:get, "#{base}/auth/REF-0001")
      .with(headers: { "Authorization" => "Bearer auth-tok" })
      .to_return(status_sequence.map { |code| { status: 200, body: JSON.generate("status" => { "code" => code }) } })
    stub_request(:post, "#{base}/auth/token/redeem")
      .with(headers: { "Authorization" => "Bearer auth-tok" })
      .to_return(status: 200, body: JSON.generate(tokens_body))
  end

  it "runs the full XAdES flow: challenge→signature→polling→redeem" do
    stub_flow([200])
    cert, key = CertificateHelper.rsa_pair
    signer = Ksef::Xades::Signer.new(cert: cert, key: key)

    result = coordinator.authenticate(context: { nip: "5555555555" }, signer: signer, poll: { interval: 0 })

    expect(result.access_token).to eq("access-tok")
    expect(result.refresh_token).to eq("refresh-tok")
    expect(result.reference_number).to eq("REF-0001")
    expect(a_request(:post, "#{base}/auth/xades-signature")
      .with(query: hash_including("verifyCertificateChain" => "false"),
            headers: { "Content-Type" => "application/xml" })).to have_been_made
  end

  it "polls until status.code == 200" do
    stub_flow([100, 100, 200])
    cert, key = CertificateHelper.rsa_pair
    coordinator.authenticate(context: { nip: "5555555555" },
                             signer: Ksef::Xades::Signer.new(cert: cert, key: key), poll: { interval: 0 })
    expect(a_request(:get, "#{base}/auth/REF-0001")).to have_been_made.times(3)
  end

  it "raises AuthenticationFailed on an error code (e.g. 450)" do
    stub_flow([450])
    cert, key = CertificateHelper.rsa_pair
    expect do
      coordinator.authenticate(context: { nip: "5555555555" },
                               signer: Ksef::Xades::Signer.new(cert: cert, key: key), poll: { interval: 0 })
    end.to raise_error(Ksef::AuthenticationFailed) { |e| expect(e.code).to eq(450) }
  end

  it "refuses an unusable signer, a key and a bad context before asking for a challenge" do
    challenge = stub_request(:post, "#{base}/auth/challenge")
    _cert, key = CertificateHelper.rsa_pair
    signer = ->(xml) { xml }

    expect { coordinator.authenticate(context: { nip: "5555555555" }, signer: Object.new) }
      .to raise_error(Ksef::ConfigurationError, /#sign\(xml\) or #call\(xml\)/)
    expect { coordinator.authenticate(context: { nip: "5555555555" }, signer: key) }
      .to raise_error(Ksef::ConfigurationError, /signer is a key/)
    { { context: { nip: "524-610-88-71" } } => /context nip/, { context: "5555555555" } => /context must be a Hash/,
      { context: { nip: "5555555555" }, subject_identifier_type: nil } => /subject_identifier_type/,
      { context: { nip: "5555555555" }, allowed_ips: ["1.1.1.1"] } => /allowed_ips must be a Hash/,
      { context: { nip: "5555555555" }, allowed_ips: { addresses: Array.new(11) { |i| "10.0.0.#{i}" } } } =>
        /at most 10/ }.each do |args, error|
      expect { coordinator.authenticate(signer: signer, **args) }.to raise_error(Ksef::ConfigurationError, error)
    end
    expect { coordinator.authenticate_with_token(context: nil, token: "t") }
      .to raise_error(Ksef::ConfigurationError, /context must be a Hash/)
    expect(challenge).not_to have_been_requested
  end

  it "refuses a signer result that is not the signed XML, before submitting it" do
    stub_request(:post, "#{base}/auth/challenge").to_return(status: 200, body: JSON.generate(challenge_body))
    submit = stub_request(:post, %r{/auth/xades-signature})

    [->(_xml) {}, ->(_xml) { "" }].each do |signer|
      expect { coordinator.authenticate(context: { nip: "5555555555" }, signer: signer) }
        .to raise_error(Ksef::CryptoError, /instead of the signed XML/)
    end
    expect(submit).not_to have_been_requested
  end

  it "raises instead of returning a result without the redeemed tokens" do
    stub_flow([200])
    stub_request(:post, "#{base}/auth/token/redeem")
      .to_return(status: 200, body: JSON.generate("accessToken" => {}, "refreshToken" => { "token" => "r" }))
    cert, key = CertificateHelper.rsa_pair

    expect do
      coordinator.authenticate(context: { nip: "5555555555" }, signer: Ksef::Xades::Signer.new(cert: cert, key: key),
                               poll: { interval: 0 })
    end.to raise_error(Ksef::ApiError, /lacks accessToken.token/)
  end

  it "raises ReauthenticationRequired when the refresh token is refused with a 401" do
    stub_request(:post, "#{base}/auth/token/refresh").to_return(
      status: 401, body: JSON.generate("title" => "Unauthorized", "status" => 401),
      headers: { "Content-Type" => "application/problem+json" }
    )

    expect { coordinator.refresh(refresh_token: "expired") }
      .to raise_error(Ksef::ReauthenticationRequired) { |error| expect(error.status).to eq(401) }
  end

  it "authenticates with an encrypted KSeF token (RSA-OAEP)" do
    stub_public_keys([mf_certificate(usage: "KsefTokenEncryption", public_key_id: "tok-key")])
    stub_request(:post, "#{base}/auth/challenge").to_return(status: 200, body: JSON.generate(challenge_body))
    ksef_token_stub = stub_request(:post, "#{base}/auth/ksef-token")
                      .to_return(status: 202, body: JSON.generate(init_body))
    stub_request(:get, "#{base}/auth/REF-0001").to_return(status: 200,
                                                          body: JSON.generate("status" => { "code" => 200 }))
    stub_request(:post, "#{base}/auth/token/redeem").to_return(status: 200, body: JSON.generate(tokens_body))

    result = coordinator.authenticate_with_token(context: { nip: "5555555555" }, token: "my-ksef-token",
                                                 poll: { interval: 0 })
    expect(result.access_token).to eq("access-tok")
    expect(ksef_token_stub).to have_been_requested
  end

  it "starts over with a fresh challenge and the refreshed key after a key rotation (21470)" do
    stub_public_keys([mf_certificate(usage: "KsefTokenEncryption", public_key_id: "tok-key")])
    challenge_stub = stub_request(:post, "#{base}/auth/challenge")
                     .to_return(status: 200, body: JSON.generate(challenge_body))
    rotation = JSON.generate("exception" => { "exceptionDetailList" => [{ "exceptionCode" => 21_470 }] })
    stub_request(:post, "#{base}/auth/ksef-token")
      .to_return({ status: 400, body: rotation }, { status: 202, body: JSON.generate(init_body) })
    stub_request(:get, "#{base}/auth/REF-0001").to_return(status: 200,
                                                          body: JSON.generate("status" => { "code" => 200 }))
    stub_request(:post, "#{base}/auth/token/redeem").to_return(status: 200, body: JSON.generate(tokens_body))

    result = coordinator.authenticate_with_token(context: { nip: "5555555555" }, token: "t", poll: { interval: 0 })

    expect(result.access_token).to eq("access-tok")
    expect(challenge_stub).to have_been_requested.twice
    expect(a_request(:get, "#{base}/security/public-key-certificates")).to have_been_made.twice
  end

  it "validates the context before calling the API" do
    expect { coordinator.authenticate_with_token(context: { regon: "1" }, token: "t") }
      .to raise_error(Ksef::ConfigurationError, /context/)
    expect { coordinator.authenticate_with_token(context: { nip: "524-610-88-71" }, token: "t") }
      .to raise_error(Ksef::ConfigurationError, /context nip is not a valid NIP/)
    expect(a_request(:post, "#{base}/auth/challenge")).not_to have_been_made
  end

  it "sends a NIP context with separators and a PL prefix as its 10 digits" do
    stub_public_keys([mf_certificate(usage: "KsefTokenEncryption", public_key_id: "tok-key")])
    stub_request(:post, "#{base}/auth/challenge").to_return(status: 200, body: JSON.generate(challenge_body))
    ksef_token_stub = stub_request(:post, "#{base}/auth/ksef-token")
                      .with { |request| JSON.parse(request.body).dig("contextIdentifier", "value") == "5260250274" }
                      .to_return(status: 202, body: JSON.generate(init_body))
    stub_request(:get, "#{base}/auth/REF-0001").to_return(status: 200,
                                                          body: JSON.generate("status" => { "code" => 200 }))
    stub_request(:post, "#{base}/auth/token/redeem").to_return(status: 200, body: JSON.generate(tokens_body))

    coordinator.authenticate_with_token(context: { nip: "PL 526-025-02-74" }, token: "t", poll: { interval: 0 })
    expect(ksef_token_stub).to have_been_requested
  end
end
