# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Sessions::Online do
  let(:base) { ClientHelper::API_BASE }
  # A known RSA key for the Ministry of Finance certificate, so the test can recover the session
  # key and verify the ciphertext.
  let(:mf_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:client) { test_client(access_token: "access-tok") }
  let(:invoice_xml) { "<Faktura><P_1>2026-02-01</P_1>ąęś</Faktura>".b }

  before do
    stub_public_keys([mf_certificate(usage: "SymmetricKeyEncryption", key: mf_key, public_key_id: "sym-1")])
  end

  def recover_session_key(encryption_json)
    encrypted_key = Base64.strict_decode64(encryption_json["encryptedSymmetricKey"])
    key = mf_key.decrypt(encrypted_key, rsa_padding_mode: "oaep", rsa_oaep_md: "sha256", rsa_mgf1_md: "sha256")
    iv = Base64.strict_decode64(encryption_json["initializationVector"])
    [key, iv]
  end

  it "opens a session with encryption material and sends an encrypted invoice" do
    open_stub = stub_request(:post, "#{base}/sessions/online")
                .to_return(status: 201, body: JSON.generate("referenceNumber" => "SESS-1"))
    send_stub = stub_request(:post, "#{base}/sessions/online/SESS-1/invoices")
                .to_return(status: 202, body: JSON.generate("referenceNumber" => "INV-1"))
    close_stub = stub_request(:post, "#{base}/sessions/online/SESS-1/close").to_return(status: 204, body: "")

    session = described_class.open(client, form_code: Ksef::FormCode::FA3)
    expect(session.reference_number).to eq("SESS-1")

    sent = session.send_invoice(invoice_xml)
    expect(sent.reference_number).to eq("INV-1")
    session.close

    expect(open_stub).to have_been_requested
    expect(send_stub).to have_been_requested
    expect(close_stub).to have_been_requested
  end

  it "sends correct hashes/sizes, and the ciphertext decrypts back to the original (no IV prefix)" do
    open_request = nil
    stub_request(:post, "#{base}/sessions/online")
      .to_return do |req|
      open_request = JSON.parse(req.body)
      { status: 201, body: JSON.generate("referenceNumber" => "SESS-2") }
    end
    send_request = nil
    stub_request(:post, "#{base}/sessions/online/SESS-2/invoices")
      .to_return do |req|
      send_request = JSON.parse(req.body)
      { status: 202, body: JSON.generate("referenceNumber" => "INV-2") }
    end

    session = described_class.open(client, form_code: Ksef::FormCode::FA3)
    session.send_invoice(invoice_xml)

    key, iv = recover_session_key(open_request["encryption"])
    ciphertext = Base64.strict_decode64(send_request["encryptedInvoiceContent"])

    # Decryption with the session key + IV from encryption alone (proof: no IV prefix).
    decrypted = client.crypto.decrypt_aes(ciphertext, key, iv)
    expect(decrypted).to eq(invoice_xml)

    # Hashes/sizes: plaintext vs ciphertext.
    expect(send_request["invoiceHash"]).to eq(Base64.strict_encode64(Digest::SHA256.digest(invoice_xml)))
    expect(send_request["invoiceSize"]).to eq(invoice_xml.bytesize)
    expect(send_request["encryptedInvoiceHash"]).to eq(Base64.strict_encode64(Digest::SHA256.digest(ciphertext)))
    expect(send_request["encryptedInvoiceSize"]).to eq(ciphertext.bytesize)
  end

  it "retries opening the session after key rotation (code 21470)" do
    stub_request(:post, "#{base}/sessions/online")
      .to_return({ status: 400,
                   body: JSON.generate("exception" => { "exceptionDetailList" => [{ "exceptionCode" => 21_470 }] }) },
                 { status: 201, body: JSON.generate("referenceNumber" => "SESS-3") })

    session = described_class.open(client, form_code: Ksef::FormCode::FA3)
    expect(session.reference_number).to eq("SESS-3")
    # two certificate fetches: the initial one and the one after rotation
    expect(a_request(:get, "#{base}/security/public-key-certificates")).to have_been_made.twice
  end

  it "keeps a caller-supplied key after a rotation, re-wrapped under the new certificate" do
    rotation = JSON.generate("exception" => { "exceptionDetailList" => [{ "exceptionCode" => 21_470 }] })
    sent = []
    stub_request(:post, "#{base}/sessions/online").to_return do |req|
      sent << JSON.parse(req.body)["encryption"]
      next { status: 400, body: rotation } if sent.size == 1

      { status: 201, body: JSON.generate("referenceNumber" => "S-4") }
    end
    own = client.crypto.encryption_data

    session = described_class.open(client, encryption: own)

    expect([session.encryption.key, session.encryption.iv]).to eq([own.key, own.iv])
    expect(sent.map { |encryption| recover_session_key(encryption) }.uniq).to eq([[own.key, own.iv]])
    expect(sent.last["encryptedSymmetricKey"]).not_to eq(sent.first["encryptedSymmetricKey"])
  end

  it "gives up after one rotation retry" do
    rotation = JSON.generate("exception" => { "exceptionDetailList" => [{ "exceptionCode" => 21_470 }] })
    stub = stub_request(:post, "#{base}/sessions/online").to_return(status: 400, body: rotation)

    expect { described_class.open(client) }.to raise_error(Ksef::BadRequest) { |e| expect(e.codes).to eq([21_470]) }
    expect(stub).to have_been_requested.twice
  end

  describe "sending" do
    let(:sent) { [] }
    let(:session) { described_class.open(client) }

    before do
      stub_request(:post, "#{base}/sessions/online").to_return(
        status: 201, body: JSON.generate("referenceNumber" => "SESS-3", "validUntil" => "2026-10-13T00:00:00Z")
      )
      stub_request(:post, "#{base}/sessions/online/SESS-3/invoices").to_return do |request|
        sent << JSON.parse(request.body)
        { status: 202, body: JSON.generate("referenceNumber" => "INV-3") }
      end
    end

    it "keeps the session's validUntil" do
      expect(session.valid_until).to eq(Time.utc(2026, 10, 13))
    end

    it "measures a UTF-8 String in bytes, frozen or not" do
      xml = "<Faktura>zażółć gęślą jaźń</Faktura>"
      [xml, xml.dup.freeze].each { |invoice| session.send_invoice(invoice) }

      expect(sent.map { |body| body["invoiceSize"] }).to eq([xml.bytesize] * 2)
      expect(xml.bytesize).to be > xml.length
    end

    it "refuses a byte order mark, bytes that are not UTF-8 and a session without its key, sending nothing" do
      expect { session.send_invoice("\uFEFF<Faktura/>") }.to raise_error(Ksef::ConfigurationError, /byte order mark/)
      expect { session.send_invoice("<F>\xB1</F>".b) }.to raise_error(Ksef::ConfigurationError, /not valid UTF-8/)
      resumed = described_class.new(client, reference_number: "SESS-3", encryption: nil)
      expect { resumed.send_invoice("<F/>") }.to raise_error(Ksef::ConfigurationError, /no encryption key/)
      expect(sent).to be_empty
    end

    it "sends a technical correction in offline mode, and refuses one declared online" do
      session.send_invoice("<F/>", hash_of_corrected_invoice: "H")
      session.send_invoice("<F/>")

      expect(sent.map { |body| [body["offlineMode"], body["hashOfCorrectedInvoice"]] })
        .to eq([[true, "H"], [false, nil]])
      expect { session.send_invoice("<F/>", offline_mode: false, hash_of_corrected_invoice: "H") }
        .to raise_error(Ksef::ConfigurationError, /offline mode/)
    end

    it "raises instead of returning a SentInvoice without a reference number" do
      stub_request(:post, "#{base}/sessions/online/SESS-3/invoices").to_return(status: 202, body: "{}")

      expect { session.send_invoice("<F/>") }.to raise_error(Ksef::ApiError, /lacks referenceNumber.*processed/)
    end
  end

  describe "#wait_for_upo" do
    let(:session) { described_class.new(client, reference_number: "S", encryption: nil) }
    let(:status_url) { "#{base}/sessions/S/invoices/I" }

    def statuses(*codes)
      stub_request(:get, status_url).to_return(codes.map do |code, extra|
        { status: 200, body: JSON.generate("status" => { "code" => code }.merge(extra || {})) }
      end)
    end

    it "keeps polling through 100 and 150, then downloads the UPO" do
      statuses(100, 150, 200)
      stub_request(:get, "#{status_url}/upo").to_return(status: 200, body: "<UPO/>")

      expect(session.wait_for_upo("I", poll: { interval: 0 })).to eq("<UPO/>")
      expect(a_request(:get, status_url)).to have_been_made.times(3)
    end

    it "raises InvoiceRejected with the codes and the status for a duplicate (440) or a rejection (450)" do
      statuses([440, { "extensions" => { "originalKsefNumber" => "K" } }])
      expect { session.wait_for_upo("I", poll: { interval: 0 }) }.to raise_error(Ksef::InvoiceRejected) { |error|
        expect([error.codes, error.status, error.body.dig("status", "extensions", "originalKsefNumber")])
          .to eq([[440], nil, "K"])
      }

      statuses([450, { "description" => "Błąd", "details" => ["P_2 missing"] }])
      expect { session.wait_for_upo("I", poll: { interval: 0 }) }.to raise_error(Ksef::InvoiceRejected) { |error|
        expect(error).to be_a(Ksef::ApiError)
        expect(error.body.dig("status", "details")).to eq(["P_2 missing"])
      }
    end

    it "raises PollingTimeout while the invoice is still processed" do
      statuses(150)

      expect { session.wait_for_upo("I", poll: { interval: 0, timeout: 0 }) }.to raise_error(Ksef::PollingTimeout)
    end
  end
end
