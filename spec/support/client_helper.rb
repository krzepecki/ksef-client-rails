# frozen_string_literal: true

# Helpers building a client pointed at the TEST host (stubbed with WebMock).
module ClientHelper
  # Base URL for API requests (including the /v2 prefix).
  API_BASE = "https://api-test.ksef.mf.gov.pl/v2"

  def test_config
    Ksef::Configuration.new(environment: :test)
  end

  def test_client(access_token: nil, config: test_config)
    Ksef::Client.new(access_token: access_token, config: config)
  end

  # Ministry of Finance certificates (public-key-certificates) in the API response format.
  def stub_public_keys(certs)
    stub_request(:get, "#{API_BASE}/security/public-key-certificates")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(certs))
  end

  # Builds a Ministry of Finance certificate entry (DER Base64) with the given usage.
  def mf_certificate(usage:, key: OpenSSL::PKey::RSA.new(2048), public_key_id: "pk-#{usage}")
    cert = CertificateHelper.self_signed(key, subject: "/CN=MF #{usage}")
    {
      "certificate" => Base64.strict_encode64(cert.to_der),
      "certificateId" => "cid-#{usage}",
      "publicKeyId" => public_key_id,
      "validFrom" => (Time.now - 86_400).iso8601,
      "validTo" => (Time.now + 86_400).iso8601,
      "usage" => [usage]
    }
  end
end

RSpec.configure { |c| c.include ClientHelper }
