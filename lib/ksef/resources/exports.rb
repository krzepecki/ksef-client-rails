# frozen_string_literal: true

module Ksef
  module Resources
    # Invoice package export resource — POST /invoices/exports + status.
    #
    # The orchestration (polling → downloading parts from presigned URLs → encryptedPartHash
    # verification → decryption → concatenation → unpacking) lives in {Ksef::Invoices::Export}.
    class Exports < Base
      EXPORTS = "/invoices/exports"

      # POST /invoices/exports — initiates a package export.
      #
      # @param encryption_info [Ksef::Crypto::CryptographyService::EncryptionInfo, Hash]
      # @param filters [Hash] query filters
      # @param only_metadata [Boolean] export metadata only (without invoice contents)
      # @param compression_type [String, nil] package compression type ("Zip" or "TarGz")
      # @return [Hash] { "referenceNumber", ... }
      def create(encryption_info:, filters:, only_metadata: false, compression_type: nil)
        body = {
          "encryption" => to_hash(encryption_info),
          "onlyMetadata" => only_metadata,
          "filters" => filters
        }
        body["compressionType"] = compression_type if compression_type
        post(EXPORTS, json: body, returns: %w[referenceNumber])
      end

      # GET /invoices/exports/{referenceNumber} — export status (package readiness, parts).
      #
      # The response includes `packageExpirationDate` (a separate error code 210 once expired,
      # not 410) and the list of parts with their presigned URLs.
      #
      # @param reference_number [String]
      # @return [Hash]
      def status(reference_number)
        get(path("invoices", "exports", reference_number), returns: %w[status])
      end

      private

      def to_hash(value)
        value.respond_to?(:to_h) ? value.to_h : value
      end
    end
  end
end
