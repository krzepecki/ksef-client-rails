# frozen_string_literal: true

module Ksef
  module Resources
    # Interactive (online) session resource — POST /sessions/online*.
    #
    # Low-level methods mapped 1:1 to endpoints; the orchestration (encryption, hashing, UPO
    # polling) lives in {Ksef::Sessions::Online}.
    class OnlineSessions < Base
      OPEN = "/sessions/online"

      # POST /sessions/online — opens an interactive session.
      # @param form_code [Ksef::FormCode, Hash] invoice schema
      # @param encryption_info [Ksef::Crypto::CryptographyService::EncryptionInfo, Hash]
      # @return [Hash] { "referenceNumber", ... }
      def open(form_code:, encryption_info:)
        post(OPEN, json: { "formCode" => to_hash(form_code), "encryption" => to_hash(encryption_info) },
                   returns: %w[referenceNumber])
      end

      # POST /sessions/online/{referenceNumber}/invoices — sends an encrypted invoice.
      #
      # @param reference_number [String] session reference number
      # @param invoice_hash [String] SHA256 (Base64) of the PLAINTEXT invoice
      # @param invoice_size [Integer] plaintext invoice size (B)
      # @param encrypted_invoice_hash [String] SHA256 (Base64) of the ENCRYPTED invoice
      # @param encrypted_invoice_size [Integer] ciphertext size (B)
      # @param encrypted_invoice_content [String] AES-256-CBC ciphertext (Base64)
      # @param offline_mode [Boolean] offline mode declaration
      # @param hash_of_corrected_invoice [String, nil] SHA256 (Base64) of the corrected invoice (a technical
      #   correction, sent with offline_mode true)
      # @return [Hash] { "referenceNumber" => <invoice reference number> }
      def send_invoice(reference_number, invoice_hash:, invoice_size:, encrypted_invoice_hash:,
                       encrypted_invoice_size:, encrypted_invoice_content:, offline_mode: false,
                       hash_of_corrected_invoice: nil)
        body = {
          "invoiceHash" => invoice_hash,
          "invoiceSize" => invoice_size,
          "encryptedInvoiceHash" => encrypted_invoice_hash,
          "encryptedInvoiceSize" => encrypted_invoice_size,
          "encryptedInvoiceContent" => encrypted_invoice_content,
          "offlineMode" => offline_mode
        }
        body["hashOfCorrectedInvoice"] = hash_of_corrected_invoice if hash_of_corrected_invoice
        post(path("sessions", "online", reference_number, "invoices"), json: body, returns: %w[referenceNumber])
      end

      # POST /sessions/online/{referenceNumber}/close — closes the session (starts processing).
      # @param reference_number [String]
      # @return [nil] (204)
      def close(reference_number)
        post(path("sessions", "online", reference_number, "close"), json: {})
      end

      private

      def to_hash(value)
        value.respond_to?(:to_h) ? value.to_h : value
      end
    end
  end
end
