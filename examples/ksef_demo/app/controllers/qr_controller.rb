# frozen_string_literal: true

# Verification QR codes, computed locally: CODE I (online invoice) and CODE II (offline invoice,
# the link signed with a KSeF Offline certificate).
class QrController < ApplicationController
  def index
    @invoice_xml = default_xml
  end

  def online
    @invoice_xml = params[:invoice_xml].to_s
    ksef_action("CODE I — online invoice") do
      url = link_builder.online(seller_nip: params[:seller_nip], issue_date: Date.parse(params[:issue_date].to_s),
                                invoice_xml: @invoice_xml)
      render_qr(url, "OFFLINE") # KSeF prints the KSeF number here once it is assigned
    end
  end

  def offline
    @invoice_xml = params[:invoice_xml].to_s
    ksef_action("CODE II — offline certificate") do
      upload = CertificateUpload.new(certificate: uploaded(:certificate_file), key: uploaded(:key_file),
                                     password: params[:certificate_password].to_s)
      cert, key = upload.certificate_and_key
      url = link_builder.offline(context_type: "Nip", context_value: settings["nip"], seller_nip: params[:seller_nip],
                                 certificate_serial: cert.serial.to_s(16).upcase, private_key: key,
                                 invoice_xml: @invoice_xml)
      render_qr(url, "CERTYFIKAT")
    end
  end

  private

  def link_builder
    Ksef::Qr::VerificationLink.new(qr_base_url: ksef_config.qr_url)
  end

  def render_qr(url, label)
    @qr = { url: url, label: label, svg: Ksef::Qr::Code.new(url, label: label).as_svg }
    { "verification link" => url }
  end

  def default_xml
    InvoiceDraft.sample(seller_nip: settings["nip"]).to_xml
  rescue Ksef::ConfigurationError, Ksef::SchemaValidationError => e
    flash.now[:alert] = "No sample invoice: #{e.message} — check the context NIP on the Overview page."
    ""
  end
end
