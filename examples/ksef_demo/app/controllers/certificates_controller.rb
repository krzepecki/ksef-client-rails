# frozen_string_literal: true

# KSeF certificates: limits, enrollment data → CSR (generated here, the key never leaves the
# server session) → enrollment → status → list, retrieve, revoke. Enrollment needs an XAdES login.
class CertificatesController < ApplicationController
  def index; end

  def limits
    ksef_action("Certificate limits") { authed_client.certificates.limits }
  end

  def enrollment_data
    ksef_action("Enrollment data") { authed_client.certificates.enrollment_data }
  end

  def enroll
    ksef_action("Certificate enrollment") do
      client = authed_client
      data = client.certificates.enrollment_data
      csr = params[:key_type] == "rsa" ? Ksef::Crypto::Csr.generate_rsa(data) : Ksef::Crypto::Csr.generate_ecdsa(data)
      response = client.certificates.enroll(certificate_name: params[:certificate_name].to_s,
                                            certificate_type: params[:certificate_type].presence || "Authentication",
                                            csr: csr.csr_der_base64)
      @key_path = stash(csr.private_key_pem, filename: "ksef-#{response['referenceNumber']}.key",
                                             type: "application/x-pem-file")
      { "reference number" => response["referenceNumber"], "subject (from enrollment data)" => data }
    end
  end

  def enrollment_status
    ksef_action("Enrollment status") { authed_client.certificates.enrollment_status(params[:reference].to_s.strip) }
  end

  def list
    ksef_action("Certificates") do
      body = { "status" => params[:status].presence, "type" => params[:type].presence }.compact
      @certificates = authed_client.certificates.query(body: body).first(50)
      { "certificates" => @certificates.size }
    end
  end

  def retrieve
    ksef_action("Retrieve certificate") do
      serial = params[:serial].to_s.strip
      cert = Array(authed_client.certificates.retrieve(certificate_serial_numbers: [serial])["certificates"]).first
      raise ArgumentError, "No certificate with serial #{serial}" unless cert

      pem = OpenSSL::X509::Certificate.new(Base64.decode64(cert["certificate"])).to_pem
      @cert_path = stash(pem, filename: "ksef-#{serial}.pem", type: "application/x-pem-file")
      cert.except("certificate")
    end
  end

  def revoke
    ksef_action("Revoke certificate") do
      authed_client.certificates.revoke(params[:serial].to_s.strip, revocation_reason: params[:reason].presence)
      { "revoked" => params[:serial] }
    end
  end
end
