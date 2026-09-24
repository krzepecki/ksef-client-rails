# frozen_string_literal: true

require "spec_helper"
require "ksef/testing"

RSpec.describe Ksef::Testing do
  include described_class

  let(:client) { Ksef::Client.new(config: Ksef::Configuration.new(environment: :test)) }
  let(:invoice_xml) { File.read(File.expand_path("../../examples/fa3_minimal.xml", __dir__)) }
  let(:responses) { [] }

  # Every JSON body the stubs answer with must match the operation's 2xx schema in the contract.
  before do
    WebMock.after_request do |request, response|
      path = request.uri.path.delete_prefix("/v2")
      operation = OpenapiContract.operation_for(request.method.to_s, path)
      body = response.body.to_s
      responses << [operation, response.status.first, body] if operation && body.start_with?("{", "[")
    end
  end

  after do
    WebMock::CallbackRegistry.reset
    expect(responses).not_to be_empty
    responses.each do |operation, status, body|
      schema = operation.response_schema(status)
      expect(schema).not_to be_nil, "#{operation.key} declares no JSON #{status} response"
      expect(OpenapiContract.validate(schema, JSON.parse(body))).to eq([]), operation.key
    end
  end

  it "signs in with a KSeF token and refreshes the access token" do
    stub_ksef_authentication

    result = Ksef::Auth::Coordinator.new(client).authenticate_with_token(context: { nip: "5555555555" },
                                                                         token: "ksef-token", poll: { interval: 0 })
    expect([result.access_token,
            result.refresh_token]).to eq([described_class::ACCESS_TOKEN, described_class::REFRESH_TOKEN])
    expect(client.auth.refresh(refresh_token: result.refresh_token).dig("accessToken", "token"))
      .to eq(described_class::ACCESS_TOKEN)
  end

  it "signs in with an XAdES signature" do
    stub_ksef_authentication(access_token: "xades-access")
    cert, key = CertificateHelper.rsa_pair

    result = Ksef::Auth::Coordinator.new(client).authenticate(context: { nip: "5555555555" },
                                                              signer: Ksef::Xades::Signer.new(cert: cert, key: key),
                                                              poll: { interval: 0 })
    expect(result.access_token).to eq("xades-access")
  end

  it "accepts every invoice of an interactive session and returns its UPO" do
    stub_ksef_online_session(upo: "<Potwierdzenie>test</Potwierdzenie>")
    authorized = client.with_access_token("token")

    session = Ksef::Sessions::Online.open(authorized)
    sent = session.send_invoice(invoice_xml)
    session.close

    expect(session.wait_for_upo(sent.reference_number,
                                poll: { interval: 0 })).to eq("<Potwierdzenie>test</Potwierdzenie>")
    ksef_number = authorized.sessions.invoice(session.reference_number, sent.reference_number)["ksefNumber"]
    expect(ksef_number).to eq(described_class.ksef_number)
    expect(Ksef::KsefNumber.new(ksef_number)).to be_valid
  end

  it "keeps the Ministry certificate valid in a test that travels in time" do
    stub_ksef_public_keys
    client.crypto.encryption_data # memoizes the stubbed certificates, as an earlier test would
    allow(Time).to receive(:now).and_return(Time.utc(2031, 6, 1))

    expect { Ksef::Client.new(config: Ksef::Configuration.new(environment: :test)).crypto.encryption_data }
      .not_to raise_error
  end

  it "stubs another environment through config:" do
    demo = Ksef::Configuration.new(environment: :demo)
    stub_ksef_public_keys(config: demo)

    expect(Ksef::Client.new(config: demo).security.public_key_certificates.size).to eq(2)
  end
end

RSpec.describe "Ksef::Testing.ksef_number" do
  it "normalizes the seller NIP and refuses an invalid one or a date the pattern refuses" do
    expect(Ksef::Testing.ksef_number(seller_nip: "PL 555-555-55-55")).to eq(Ksef::Testing.ksef_number)
    expect { Ksef::Testing.ksef_number(seller_nip: "1234567890") }.to raise_error(Ksef::ConfigurationError)
    expect { Ksef::Testing.ksef_number(date: Date.new(2019, 1, 1)) }
      .to raise_error(Ksef::ConfigurationError, /Invalid KSeF number/)
  end
end
