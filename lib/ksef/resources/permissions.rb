# frozen_string_literal: true

module Ksef
  module Resources
    # KSeF permissions resource — /permissions/* endpoints: grants, revocations and
    # queries (offset pagination). Request bodies are nested, so they are passed through as a
    # ready `body:` hash. Every endpoint requires an accessToken.
    class Permissions < Base
      PERSONS_GRANTS = "/permissions/persons/grants"
      ENTITIES_GRANTS = "/permissions/entities/grants"
      AUTHORIZATIONS_GRANTS = "/permissions/authorizations/grants"
      INDIRECT_GRANTS = "/permissions/indirect/grants"
      SUBUNITS_GRANTS = "/permissions/subunits/grants"
      EU_ENTITIES_GRANTS = "/permissions/eu-entities/grants"
      EU_ENTITIES_ADMIN_GRANTS = "/permissions/eu-entities/administration/grants"
      QUERY_PERSONS = "/permissions/query/persons/grants"
      QUERY_PERSONAL = "/permissions/query/personal/grants"
      QUERY_ENTITIES = "/permissions/query/entities/grants"
      QUERY_AUTHORIZATIONS = "/permissions/query/authorizations/grants"
      QUERY_EU_ENTITIES = "/permissions/query/eu-entities/grants"
      QUERY_SUBUNITS = "/permissions/query/subunits/grants"
      QUERY_ENTITY_ROLES = "/permissions/query/entities/roles"
      QUERY_SUBORDINATE_ROLES = "/permissions/query/subordinate-entities/roles"
      ATTACHMENTS_STATUS = "/permissions/attachments/status"

      # POST /permissions/persons/grants — grants permissions to a natural person.
      # @param body [Hash] PersonPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_persons(body:)
        post(PERSONS_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # POST /permissions/entities/grants — grants permissions to an entity.
      # @param body [Hash] EntityPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_entities(body:)
        post(ENTITIES_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # POST /permissions/authorizations/grants — grants an authorization-type permission.
      # @param body [Hash] EntityAuthorizationPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_authorizations(body:)
        post(AUTHORIZATIONS_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # POST /permissions/indirect/grants — grants indirect permissions.
      # @param body [Hash] IndirectPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_indirect(body:)
        post(INDIRECT_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # POST /permissions/subunits/grants — grants permissions within a subunit.
      # @param body [Hash] SubunitPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_subunits(body:)
        post(SUBUNITS_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # POST /permissions/eu-entities/grants — grants permissions to an EU entity.
      # @param body [Hash] EuEntityPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_eu_entities(body:)
        post(EU_ENTITIES_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # POST /permissions/eu-entities/administration/grants — grants EU entity administrative permissions.
      # @param body [Hash] EuEntityAdministrationPermissionsGrantRequest
      # @return [Hash] { "referenceNumber" }
      def grant_eu_entity_administration(body:)
        post(EU_ENTITIES_ADMIN_GRANTS, json: body, returns: %w[referenceNumber])
      end

      # DELETE /permissions/common/grants/{permissionId} — revokes a permission (common).
      # @param permission_id [String]
      # @return [Hash] { "referenceNumber" }
      def revoke_common(permission_id)
        delete(path("permissions", "common", "grants", permission_id), returns: %w[referenceNumber])
      end

      # DELETE /permissions/authorizations/grants/{permissionId} — revokes an authorization.
      # @param permission_id [String]
      # @return [Hash] { "referenceNumber" }
      def revoke_authorization(permission_id)
        delete(path("permissions", "authorizations", "grants", permission_id), returns: %w[referenceNumber])
      end

      # POST /permissions/query/persons/grants — query person permissions (offset pagination).
      # @param body [Hash] PersonPermissionsQueryRequest (requires "queryType")
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_persons(body:, page_size: 10)
        offset_query(QUERY_PERSONS, body, "permissions", page_size)
      end

      # POST /permissions/query/personal/grants — query own permissions (offset pagination).
      # @param body [Hash] PersonalPermissionsQueryRequest
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_personal(body: {}, page_size: 10)
        offset_query(QUERY_PERSONAL, body, "permissions", page_size)
      end

      # POST /permissions/query/entities/grants — query entity permissions (offset pagination).
      # @param body [Hash] EntityPermissionsQueryRequest
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_entities(body: {}, page_size: 10)
        offset_query(QUERY_ENTITIES, body, "permissions", page_size)
      end

      # POST /permissions/query/authorizations/grants — query authorizations (offset pagination).
      # @param body [Hash] EntityAuthorizationPermissionsQueryRequest (requires "queryType")
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_authorizations(body:, page_size: 10)
        offset_query(QUERY_AUTHORIZATIONS, body, "authorizationGrants", page_size)
      end

      # POST /permissions/query/eu-entities/grants — query EU entity permissions (offset pagination).
      # @param body [Hash] EuEntityPermissionsQueryRequest
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_eu_entities(body: {}, page_size: 10)
        offset_query(QUERY_EU_ENTITIES, body, "permissions", page_size)
      end

      # POST /permissions/query/subunits/grants — query subunit permissions (offset pagination).
      # @param body [Hash] SubunitPermissionsQueryRequest
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_subunits(body: {}, page_size: 10)
        offset_query(QUERY_SUBUNITS, body, "permissions", page_size)
      end

      # GET /permissions/query/entities/roles — entity roles (offset pagination, no body).
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_entity_roles(page_size: 10)
        Http::Pagination.by_offset(page_size: page_size) do |page, size|
          data = get(QUERY_ENTITY_ROLES, query: { "pageOffset" => page, "pageSize" => size }, returns: [])
          Http::Pagination::OffsetPage.new(items: data["roles"] || [], has_more: data["hasMore"])
        end
      end

      # POST /permissions/query/subordinate-entities/roles — subordinate entity roles (offset pagination).
      # @param body [Hash] SubordinateEntityRolesQueryRequest
      # @param page_size [Integer]
      # @return [Enumerator::Lazy<Hash>]
      def query_subordinate_entity_roles(body: {}, page_size: 10)
        offset_query(QUERY_SUBORDINATE_ROLES, body, "roles", page_size)
      end

      # GET /permissions/operations/{referenceNumber} — status of a grant/revoke operation.
      # @param reference_number [String]
      # @return [Hash] { "status" => { "code", "description", "details" } }
      def operation_status(reference_number)
        get(path("permissions", "operations", reference_number), returns: %w[status])
      end

      # GET /permissions/attachments/status — whether attachments are allowed in the current context.
      # @return [Hash] { "isAttachmentAllowed", "revokedDate" }
      def attachment_status
        get(ATTACHMENTS_STATUS, returns: [])
      end

      private

      # Shared POST query mechanism with offset pagination (pageOffset/pageSize + hasMore).
      # @return [Enumerator::Lazy<Hash>]
      def offset_query(url, body, items_key, page_size)
        Http::Pagination.by_offset(page_size: page_size) do |page, size|
          data = post(url, json: body, query: { "pageOffset" => page, "pageSize" => size }, returns: [])
          Http::Pagination::OffsetPage.new(items: data[items_key] || [], has_more: data["hasMore"])
        end
      end
    end
  end
end
