# frozen_string_literal: true

module Ksef
  module Resources
    # Session read/status resource — GET /sessions* endpoints.
    #
    # Covers the session list, session status, invoice lists (including failed ones) and UPO
    # downloads (per invoice, per session). Lists use continuation-token pagination; UPO is XML.
    class Sessions < Base
      SESSIONS = "/sessions"
      # Values of the required `sessionType` parameter of GET /sessions.
      SESSION_TYPES = %w[Online Batch].freeze
      # Optional filters of GET /sessions → query parameter names.
      LIST_FILTERS = {
        reference_number: "referenceNumber", statuses: "statuses",
        date_created_from: "dateCreatedFrom", date_created_to: "dateCreatedTo",
        date_closed_from: "dateClosedFrom", date_closed_to: "dateClosedTo",
        date_modified_from: "dateModifiedFrom", date_modified_to: "dateModifiedTo"
      }.freeze

      # GET /sessions — session list (continuation-token pagination).
      # @param session_type [String, Symbol] "Online" or "Batch" (required by the API)
      # @param page_size [Integer] 10..1000
      # @param filters [Hash] optional {LIST_FILTERS}: reference_number:, statuses: (e.g.
      #   %w[InProgress Succeeded Failed Cancelled]), date_created_from:/_to:, date_closed_from:/_to:,
      #   date_modified_from:/_to: (ISO 8601)
      # @return [Enumerator::Lazy<Hash>]
      # @raise [Ksef::ConfigurationError] for any other session type or an unknown filter (raised eagerly)
      def list(session_type:, page_size: 20, **filters)
        type = validate_session_type(session_type) # eagerly — the enumerator below is lazy
        unknown = filters.keys - LIST_FILTERS.keys
        raise ConfigurationError, "Unknown session filter(s): #{unknown.join(', ')}" unless unknown.empty?

        params = filters.compact.to_h { |key, value| [LIST_FILTERS.fetch(key), value] }
        Http::Pagination.by_continuation(page_size: page_size) do |token, size|
          query = { "sessionType" => type, "pageSize" => size }.merge(params)
          headers = token ? { "x-continuation-token" => token } : {}
          body = get(SESSIONS, query: query, headers: headers, returns: [])
          Http::Pagination::ContinuationPage.new(
            items: body["sessions"] || body["items"] || [],
            continuation_token: body["continuationToken"]
          )
        end
      end

      # GET /sessions/{referenceNumber} — session status (invoice counters, final status).
      # @param reference_number [String]
      # @return [Hash]
      def status(reference_number)
        get(path("sessions", reference_number), returns: %w[status])
      end

      # GET /sessions/{referenceNumber}/invoices — session invoices (continuation pagination).
      # @param reference_number [String]
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def invoices(reference_number, page_size: 20)
        paginate_invoices(path("sessions", reference_number, "invoices"), page_size)
      end

      # GET /sessions/{referenceNumber}/invoices/failed — rejected invoices (with errors).
      # @param reference_number [String]
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def failed_invoices(reference_number, page_size: 20)
        paginate_invoices(path("sessions", reference_number, "invoices", "failed"), page_size)
      end

      # GET /sessions/{referenceNumber}/invoices/{invoiceReferenceNumber} — status of a single invoice.
      # @param reference_number [String]
      # @param invoice_reference_number [String]
      # @return [Hash]
      def invoice(reference_number, invoice_reference_number)
        get(path("sessions", reference_number, "invoices", invoice_reference_number), returns: %w[status])
      end

      # GET /sessions/{referenceNumber}/invoices/{invoiceReferenceNumber}/upo — invoice UPO (XML).
      # @param reference_number [String] session reference number
      # @param invoice_reference_number [String]
      # @return [String] UPO document (application/xml), checked against `x-ms-meta-hash`
      # @raise [Ksef::ApiError] for a 2xx that is no XML document or does not match its hash
      def invoice_upo(reference_number, invoice_reference_number)
        get_raw(path("sessions", reference_number, "invoices", invoice_reference_number, "upo"))
      end

      # GET /sessions/{referenceNumber}/invoices/ksef/{ksefNumber}/upo — invoice UPO by KSeF number (XML).
      # @param reference_number [String] session reference number
      # @param ksef_number [String]
      # @return [String] UPO document (application/xml), checked against `x-ms-meta-hash`
      # @raise [Ksef::ApiError] for a 2xx that is no XML document or does not match its hash
      def invoice_upo_by_ksef(reference_number, ksef_number)
        get_raw(path("sessions", reference_number, "invoices", "ksef", ksef_number, "upo"))
      end

      # GET /sessions/{referenceNumber}/upo/{upoReferenceNumber} — aggregate session UPO (XML).
      # @param reference_number [String] session reference number
      # @param upo_reference_number [String] from the session status (`upo.pages[].referenceNumber`)
      # @return [String] UPO document (application/xml), checked against `x-ms-meta-hash`
      # @raise [Ksef::ApiError] for a 2xx that is no XML document or does not match its hash
      def session_upo(reference_number, upo_reference_number)
        get_raw(path("sessions", reference_number, "upo", upo_reference_number))
      end

      private

      def validate_session_type(value)
        type = value.to_s.capitalize
        return type if SESSION_TYPES.include?(type)

        raise ConfigurationError, "session_type must be one of #{SESSION_TYPES.join('/')}, got #{value.inspect}"
      end

      def paginate_invoices(endpoint, page_size)
        Http::Pagination.by_continuation(page_size: page_size) do |token, size|
          headers = token ? { "x-continuation-token" => token } : {}
          body = get(endpoint, query: { "pageSize" => size }, headers: headers, returns: [])
          Http::Pagination::ContinuationPage.new(
            items: body["invoices"] || body["items"] || [],
            continuation_token: body["continuationToken"]
          )
        end
      end
    end
  end
end
