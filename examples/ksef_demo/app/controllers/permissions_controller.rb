# frozen_string_literal: true

# Permissions: a curated set of queries, a grant to a person (built from a small form, the body
# is shown before it goes out), the operation status and revocation.
class PermissionsController < ApplicationController
  # name => [label, lambda(permissions resource)]
  QUERIES = {
    "personal" => ["My own permissions", ->(p) { p.query_personal.first(50) }],
    "persons_current" => ["Persons — permissions in the current context",
                          ->(p) { p.query_persons(body: { "queryType" => "PermissionsInCurrentContext" }).first(50) }],
    "persons_granted" => ["Persons — permissions granted in the current context",
                          lambda { |p|
                            p.query_persons(body: { "queryType" => "PermissionsGrantedInCurrentContext" }).first(50)
                          }],
    "entities" => ["Entities — invoice-handling grants", ->(p) { p.query_entities.first(50) }],
    "authorizations_granted" => ["Authorizations granted",
                                 ->(p) { p.query_authorizations(body: { "queryType" => "Granted" }).first(50) }],
    "authorizations_received" => ["Authorizations received",
                                  ->(p) { p.query_authorizations(body: { "queryType" => "Received" }).first(50) }],
    "entity_roles" => ["Entity roles", ->(p) { p.query_entity_roles.first(50) }],
    "subordinate_roles" => ["Subordinate entity roles", ->(p) { p.query_subordinate_entity_roles.first(50) }],
    "subunits" => ["Subunit administrators", ->(p) { p.query_subunits.first(50) }],
    "eu_entities" => ["EU entities", ->(p) { p.query_eu_entities.first(50) }],
    "attachments" => ["Attachment status", lambda(&:attachment_status)]
  }.freeze

  PERMISSIONS = %w[InvoiceRead InvoiceWrite CredentialsRead CredentialsManage Introspection SubunitManage
                   EnforcementOperations CollectiveIdentifierManage].freeze

  def index; end

  def query
    label, query = QUERIES.fetch(params[:query], QUERIES["personal"])
    ksef_action(label) { query.call(authed_client.permissions) }
  end

  def grant
    ksef_action("Grant permissions to a person") do
      body = {
        "subjectIdentifier" => { "type" => params[:identifier_type], "value" => params[:identifier].to_s.strip },
        "permissions" => Array(params[:permissions]) & PERMISSIONS,
        "description" => params[:description].to_s,
        "subjectDetails" => subject_details
      }
      { "request body" => body }.merge(authed_client.permissions.grant_persons(body: body))
    end
  end

  def operation
    ksef_action("Operation status") { authed_client.permissions.operation_status(params[:reference].to_s.strip) }
  end

  def revoke
    ksef_action("Revoke permission") { authed_client.permissions.revoke_common(params[:permission_id].to_s.strip) }
  end

  private

  # `PersonByIdentifier` is for a certificate (or Trusted Profile) carrying the NIP/PESEL; a fingerprint
  # stands for a certificate without them, of a person who has a NIP/PESEL or has neither.
  def subject_details
    person = { "firstName" => params[:first_name].to_s.strip, "lastName" => params[:last_name].to_s.strip }
    unless params[:identifier_type] == "Fingerprint"
      return { "subjectDetailsType" => "PersonByIdentifier", "personById" => person }
    end

    if params[:person_identifier].present?
      identifier = { "type" => params[:person_identifier_type].presence_in(%w[Pesel Nip]) || "Pesel",
                     "value" => params[:person_identifier].to_s.strip }
      return { "subjectDetailsType" => "PersonByFingerprintWithIdentifier",
               "personByFpWithId" => person.merge("identifier" => identifier) }
    end

    { "subjectDetailsType" => "PersonByFingerprintWithoutIdentifier",
      "personByFpNoId" => person.merge("birthDate" => required(:birth_date), "idDocument" => id_document) }
  end

  def id_document
    { "type" => required(:document_type), "number" => required(:document_number),
      "country" => required(:document_country).upcase }
  end

  def required(name)
    params[name].to_s.strip.presence ||
      raise(ArgumentError, "A fingerprint grant without the person's PESEL/NIP needs the birth date and an identity " \
                           "document (type, number, country) — #{name.to_s.humanize(capitalize: false)} is missing.")
  end
end
