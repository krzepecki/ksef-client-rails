# frozen_string_literal: true

module Ksef
  module Resources
    # Batch session resource — POST /sessions/batch*.
    #
    # Low-level 1:1 methods; package building, splitting and uploading live in {Ksef::Batch::Uploader}.
    class BatchSessions < Base
      OPEN = "/sessions/batch"

      # POST /sessions/batch — declares a batch session (package + parts).
      #
      # @param form_code [Ksef::FormCode, Hash]
      # @param batch_file [Hash] package metadata: { "fileSize", "fileHash", "compressionType"?, "fileParts" => [...] }
      #   where fileParts is [{ "ordinalNumber", "fileSize", "fileHash" }] (no fileName) and
      #   compressionType is "Zip" (the default) or "TarGz"
      # @param encryption_info [Ksef::Crypto::CryptographyService::EncryptionInfo, Hash]
      # @param offline_mode [Boolean]
      # @return [Hash] { "referenceNumber", "partUploadRequests" => [ {url, method, headers, ...} ] }
      def open(form_code:, batch_file:, encryption_info:, offline_mode: false)
        post(OPEN, json: {
               "formCode" => to_hash(form_code),
               "batchFile" => batch_file,
               "encryption" => to_hash(encryption_info),
               "offlineMode" => offline_mode
             }, returns: %w[referenceNumber partUploadRequests])
      end

      # POST /sessions/batch/{referenceNumber}/close — closes the batch session once parts are uploaded.
      # @param reference_number [String]
      # @return [nil] (204)
      def close(reference_number)
        post(path("sessions", "batch", reference_number, "close"), json: {})
      end

      private

      def to_hash(value)
        value.respond_to?(:to_h) ? value.to_h : value
      end
    end
  end
end
