# frozen_string_literal: true

require "base64"

module Ksef
  module Sessions
    # Interactive session orchestrator: open → encrypt+hash → send → close → UPO. A session lasts 12 hours
    # ({#valid_until}) and takes up to 10,000 invoices.
    #
    # One key+IV per session; the payload is plain AES-256-CBC ciphertext WITHOUT an IV prefix
    # (see CryptographyService), and `encryptedInvoiceHash`/`encryptedInvoiceSize` cover that ciphertext.
    class Online
      # Result of sending an invoice: reference number + computed metadata (plaintext and ciphertext).
      SentInvoice = Struct.new(:reference_number, :invoice_metadata, :encrypted_metadata, keyword_init: true)

      # @return [Ksef::Client]
      attr_reader :client
      # @return [String] session reference number
      attr_reader :reference_number
      # @return [Ksef::Crypto::CryptographyService::EncryptionData, nil]
      attr_reader :encryption
      # @return [Time, nil] when KSeF closes the session by itself (`validUntil`); nil when not known
      attr_reader :valid_until

      # Opens a new interactive session.
      #
      # Public key rotation: on error 21470 the Ministry of Finance certificates are refreshed and
      # the call is retried once, with the same key wrapped under the new certificate.
      #
      # @param client [Ksef::Client]
      # @param form_code [Ksef::FormCode, Hash]
      # @param encryption [Ksef::Crypto::CryptographyService::EncryptionData, nil] generated when nil
      # @return [Online]
      def self.open(client, form_code: FormCode::FA3, encryption: nil)
        enc = encryption || client.crypto.encryption_data
        response = client.public_keys.with_rotation_retry do |retrying|
          enc = client.crypto.rewrap(enc) if retrying
          client.online.open(form_code: form_code, encryption_info: enc.encryption_info)
        end
        new(client, reference_number: response["referenceNumber"], encryption: enc,
                    valid_until: parse_time(response["validUntil"]))
      end

      # @api private
      def self.parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
      private_class_method :parse_time

      # @param client [Ksef::Client]
      # @param reference_number [String]
      # @param encryption [Ksef::Crypto::CryptographyService::EncryptionData, nil] the session's key; nil for
      #   a session resumed only to close it, read its status or wait for UPOs
      # @param valid_until [Time, nil]
      def initialize(client, reference_number:, encryption:, valid_until: nil)
        @client = client
        @reference_number = reference_number
        @encryption = encryption
        @valid_until = valid_until
      end

      # Encrypts, hashes and sends the invoice.
      #
      # @param xml [String] invoice XML: UTF-8 without a BOM, as KSeF requires
      # @param offline_mode [Boolean, nil] offline mode declaration; nil — true for a technical correction,
      #   false otherwise
      # @param hash_of_corrected_invoice [String, nil] SHA256 (Base64) of the corrected invoice — a technical
      #   correction, which resends an offline invoice and so is always sent in offline mode
      # @return [SentInvoice]
      # @raise [Ksef::ConfigurationError] for a BOM or bytes that are not UTF-8, a technical correction with
      #   `offline_mode: false`, or a session without its encryption key — before anything is sent
      def send_invoice(xml, offline_mode: nil, hash_of_corrected_invoice: nil)
        offline_mode = offline_mode(offline_mode, hash_of_corrected_invoice)
        plaintext = checked_bytes(xml)
        ciphertext = client.crypto.encrypt_aes(plaintext, encryption.key, encryption.iv)
        plain_meta = client.crypto.metadata(plaintext)
        cipher_meta = client.crypto.metadata(ciphertext)

        response = client.online.send_invoice(
          reference_number,
          invoice_hash: plain_meta.hash_sha,
          invoice_size: plain_meta.size,
          encrypted_invoice_hash: cipher_meta.hash_sha,
          encrypted_invoice_size: cipher_meta.size,
          encrypted_invoice_content: Base64.strict_encode64(ciphertext),
          offline_mode: offline_mode,
          hash_of_corrected_invoice: hash_of_corrected_invoice
        )
        SentInvoice.new(
          reference_number: response["referenceNumber"],
          invoice_metadata: plain_meta,
          encrypted_metadata: cipher_meta
        )
      end

      # Closes the session (starts final processing and UPO issuance).
      # @return [void]
      def close
        client.online.close(reference_number)
      end

      # @return [Hash] session status
      def status
        client.sessions.status(reference_number)
      end

      # Waits until the invoice is accepted and downloads its UPO (XML).
      #
      # `440` here means "duplicate invoice"; at session level the same code means "cancelled".
      #
      # @param invoice_reference_number [String]
      # @param poll [Hash] polling options
      # @return [String] UPO document (application/xml)
      # @raise [Ksef::InvoiceRejected] when KSeF rejected the invoice; any other error leaves it possibly
      #   accepted — call again
      def wait_for_upo(invoice_reference_number, poll: {})
        Polling.run(description: "UPO #{invoice_reference_number}", logger: client.config.logger, **poll) do
          info = client.sessions.invoice(reference_number, invoice_reference_number)
          interpret_invoice_status(info)
        end
        client.sessions.invoice_upo(reference_number, invoice_reference_number)
      end

      private

      def offline_mode(offline_mode, hash_of_corrected_invoice)
        return !hash_of_corrected_invoice.nil? if offline_mode.nil?
        return offline_mode if offline_mode || hash_of_corrected_invoice.nil?

        raise ConfigurationError, "a technical correction (hash_of_corrected_invoice) is sent in offline mode"
      end

      def checked_bytes(xml)
        unless encryption
          raise ConfigurationError, "session #{reference_number} has no encryption key (resumed with " \
                                    "encryption: nil) — open a new session to send invoices"
        end
        bytes = xml.b
        if bytes.start_with?("\xEF\xBB\xBF".b)
          raise ConfigurationError, "the invoice starts with a byte order mark, which KSeF refuses"
        end

        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        raise ConfigurationError, "the invoice is not valid UTF-8" unless utf8.valid_encoding?

        bytes
      end

      def interpret_invoice_status(info)
        code = info.dig("status", "code")
        case code
        when nil, 100, 150, 200..299 then handle_progress(info, code)
        when 440 then raise InvoiceRejected.new("Duplicate invoice", codes: [440], body: info)
        else
          message = info.dig("status", "description") || "Invoice error"
          raise InvoiceRejected.new(message, codes: [code].compact, body: info)
        end
      end

      # 200 = accepted (UPO available); the remaining "in progress" codes keep polling.
      def handle_progress(info, code)
        code == 200 ? info : Polling.pending
      end
    end
  end
end
