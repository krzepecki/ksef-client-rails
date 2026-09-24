# frozen_string_literal: true

module Ksef
  module Resources
    # KSeF certificate resource — /certificates/* endpoints.
    #
    # Handles certificate requests (enrollment), limit checks, listing, retrieval and
    # revocation. Every endpoint requires an accessToken (the default bearer).
    class Certificates < Base
      ENROLLMENTS = "/certificates/enrollments"
      ENROLLMENTS_DATA = "/certificates/enrollments/data"
      LIMITS = "/certificates/limits"
      QUERY = "/certificates/query"
      RETRIEVE = "/certificates/retrieve"

      # POST /certificates/enrollments — submits a certificate request (based on a CSR).
      # @param certificate_name [String] certificate name
      # @param certificate_type [String] type ("Authentication" or "Offline")
      # @param csr [String] Base64-encoded PKCS#10 request
      # @param valid_from [String, nil] validity start date (ISO-8601)
      # @return [Hash] { "referenceNumber", "timestamp" }
      def enroll(certificate_name:, certificate_type:, csr:, valid_from: nil)
        body = {
          "certificateName" => certificate_name,
          "certificateType" => certificate_type,
          "csr" => csr,
          "validFrom" => valid_from
        }.compact
        post(ENROLLMENTS, json: body, returns: %w[referenceNumber])
      end

      # GET /certificates/enrollments/data — data needed to build the CSR (the subject DN).
      # @return [Hash] { "commonName", "countryName", ... }
      def enrollment_data
        get(ENROLLMENTS_DATA, returns: [])
      end

      # GET /certificates/enrollments/{referenceNumber} — certificate request status.
      # @param reference_number [String]
      # @return [Hash] { "requestDate", "status", "certificateSerialNumber" }
      def enrollment_status(reference_number)
        get(path("certificates", "enrollments", reference_number), returns: %w[status])
      end

      # GET /certificates/limits — request and certificate limits for the subject.
      # @return [Hash] { "canRequest", "enrollment" => {...}, "certificate" => {...} }
      def limits
        get(LIMITS, returns: [])
      end

      # POST /certificates/query — certificate search (offset pagination).
      # Filter fields (all optional) in `body`: "certificateSerialNumber", "name",
      # "type" ("Authentication"/"Offline"), "status" ("Active"/"Blocked"/"Revoked"/"Expired"),
      # "expiresAfter" (ISO-8601).
      # @param body [Hash] QueryCertificatesRequest
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>] certificate entries
      def query(body: {}, page_size: 10)
        Http::Pagination.by_offset(page_size: page_size) do |page, size|
          data = post(QUERY, json: body, query: { "pageOffset" => page, "pageSize" => size }, returns: [])
          Http::Pagination::OffsetPage.new(items: data["certificates"] || [], has_more: data["hasMore"])
        end
      end

      # POST /certificates/retrieve — retrieves certificates by serial numbers.
      # @param certificate_serial_numbers [Array<String>]
      # @return [Hash] { "certificates" => [ { "certificate", "certificateName", ... } ] }
      def retrieve(certificate_serial_numbers:)
        post(RETRIEVE, json: { "certificateSerialNumbers" => certificate_serial_numbers }, returns: [])
      end

      # POST /certificates/{certificateSerialNumber}/revoke — revokes a certificate.
      # @param certificate_serial_number [String]
      # @param revocation_reason [String, nil] "Unspecified" / "Superseded" / "KeyCompromise"
      # @return [nil]
      def revoke(certificate_serial_number, revocation_reason: nil)
        body = { "revocationReason" => revocation_reason }.compact
        post(path("certificates", certificate_serial_number, "revoke"), json: body)
      end
    end
  end
end
