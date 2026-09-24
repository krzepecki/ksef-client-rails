# frozen_string_literal: true

require "spec_helper"

# Every request the gem makes, checked against the KSeF OpenAPI document it targets (taken from the
# TEST server, spec/fixtures/openapi/): the operation exists, path and query values fit their schemas,
# required parameters are sent and no undeclared ones, tokens go where the contract wants them, and
# JSON bodies match their schemas. Responses come from the document's own examples, so the flows run
# on realistic data; every list is served in two pages.
RSpec.describe "KSeF API contract (OpenAPI #{OpenapiContract.version})" do
  api = %r{\Ahttps://api-test\.ksef\.mf\.gov\.pl/v2/}

  # The default adapter, noting each query string as sent: WebMock's request signature keeps only the
  # last value of a repeated key.
  let(:client) do
    sent = sent_queries
    adapter = Class.new(Faraday::Adapter::NetHttpPersistent) do
      define_method(:call) do |env|
        sent << env.url.query
        super(env)
      end
    end
    test_client(access_token: "access-token", config: test_config.tap { |config| config.adapter = adapter })
  end
  let(:sent_queries) { [] }
  let(:recorded) { [] }
  let(:queries) { {}.compare_by_identity } # request → its [name, value] pairs
  let(:walks) { [] }
  let(:paging) { {} } # list operation → the page index or continuation token it must ask for next
  let(:paging_errors) { [] }
  let(:list_requests) { Hash.new(0) }
  let(:reference) { "20250625-SE-319D7EE000-B67F415CDC-2C" }
  let(:invoice_reference) { "20250625-EE-2A4B6C8D00-1F3E5D7C9B-3D" }
  let(:upo_reference) { "20250625-SU-5C7E9A1B00-4D6F8B0A2C-4E" }
  let(:permission_ids) { %w[0c9a72e8-f344-457f-9c16-7c640eb60242 7f3d1a52-0b6e-4c8a-9d21-5e4f6a7b8c9d] }
  let(:ksef_number) { "5265877635-20250826-0100001AF629-AF" }
  let(:serial) { "0123456789ABCDEF" }
  let(:moment) { "2026-10-01T12:00:00+02:00" }
  let(:corrected_hash) { Base64.strict_encode64(Digest::SHA256.digest("corrected invoice")) }
  let(:invoice_xml) { File.read(File.expand_path("../../examples/fa3_minimal.xml", __dir__)) }

  def operation(key)
    OpenapiContract.operation(key)
  end

  # The request example the document gives for an operation.
  def example_body(key)
    OpenapiContract.example(operation(key).request_content["application/json"])
  end

  def example_response(key)
    operation(key).success_example.last
  end

  # Ministry keys the gem can actually encrypt with; `publicKeyId` is 44 characters, as in the contract.
  def public_keys
    @public_keys ||= %w[SymmetricKeyEncryption KsefTokenEncryption].map do |usage|
      mf_certificate(usage: usage, public_key_id: Base64.strict_encode64(Random.bytes(32)))
    end
  end

  def respond(request)
    found = operation_of(request)
    return { status: 404, body: "" } unless found
    return { status: 200, body: JSON.generate(public_keys) } if found.key == "GET /security/public-key-certificates"
    # A page index that never advances would loop forever; stop the run instead.
    if paginated?(found) && (list_requests[found.key] += 1) > 20
      raise "#{found.key}: over 20 requests, the list never ends"
    end

    status, content_type, example = found.success_example
    return xml_response(status, content_type) if content_type == "application/xml"

    example = OpenapiContract.sample(found.response_schema(status, content_type)) if example.nil? && content_type
    body = paginate(found, request, example)
    { status: status, headers: { "Content-Type" => content_type.to_s },
      body: body.is_a?(String) ? body : JSON.generate(body) }
  end

  # The document gives no XML examples (invoices, UPOs); the hash header is the one it declares.
  def xml_response(status, content_type)
    { status: status, body: xml_document,
      headers: { "Content-Type" => content_type, "x-ms-meta-hash" => Digest::SHA256.base64digest(xml_document) } }
  end

  def xml_document
    %(<?xml version="1.0" encoding="UTF-8"?><Potwierdzenie/>)
  end

  def declares?(found, location, name)
    found.parameters(location).any? { |parameter| parameter["name"] == name }
  end

  def paginated?(found)
    declares?(found, "query", "pageOffset") || declares?(found, "header", "x-continuation-token")
  end

  # The one array of a list page: the items.
  def items_key(page)
    page.find { |_, value| value.is_a?(Array) }&.first
  end

  # Serves a list in two pages: the first request is told there is more, the second (page index 1, or
  # the continuation token just handed out) ends the list. Any other request is an error and gets an
  # empty last page.
  def paginate(found, request, example)
    return example || "" unless example.is_a?(Hash)

    if declares?(found, "query", "pageOffset")
      offset_page(found.key, query_value(request, "pageOffset") || "0", example)
    elsif declares?(found, "header", "x-continuation-token")
      continuation_page(found.key, request.headers["X-Continuation-Token"], example)
    else
      example
    end
  end

  def offset_page(key, page, example)
    expected = paging.delete(key)
    if expected.nil? && page == "0"
      paging[key] = "1"
      return example.merge("hasMore" => true)
    end
    return example.merge("hasMore" => false) if page == expected

    last_page(key, "pageOffset #{page}, expected #{expected || 0}", example.merge("hasMore" => false))
  end

  def continuation_page(key, token, example)
    expected = paging.delete(key)
    if expected.nil? && token.nil?
      paging[key] = SecureRandom.uuid
      return example.merge("continuationToken" => paging[key])
    end
    return example.merge("continuationToken" => nil) if token == expected

    last_page(key, "x-continuation-token #{token.inspect}, expected #{expected.inspect}",
              example.merge("continuationToken" => nil))
  end

  def last_page(key, error, page)
    paging_errors << "#{key}: #{error}"
    page.merge(items_key(page) => [])
  end

  def operation_of(request)
    OpenapiContract.operation_for(request.method.to_s, request.uri.path.delete_prefix("/v2"))
  end

  def query_pairs(request)
    queries.fetch(request)
  end

  def query_value(request, name)
    query_pairs(request).find { |key, _| key == name }&.last
  end

  def path_values(request)
    operation_of(request).path_values(request.uri.path.delete_prefix("/v2"))
  end

  def contract_errors(request)
    found = operation_of(request)
    return ["#{request.method.upcase} #{request.uri.path}: not in the contract"] unless found

    errors = path_errors(found, request) + query_errors(found, request) + token_errors(found, request) +
             body_errors(found, request)
    errors.map { |error| "#{found.key}: #{error}" }
  end

  def path_errors(found, request)
    values = path_values(request)
    found.parameters("path").flat_map do |parameter|
      name = parameter["name"]
      next ["missing path parameter #{name}"] unless values.key?(name)

      OpenapiContract.validate(parameter["schema"], values[name], "{#{name}}")
    end
  end

  # Every value sent, repeated keys included.
  def query_errors(found, request)
    sent = query_pairs(request).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    declared = found.parameters("query").to_h { |parameter| [parameter["name"], parameter] }
    required = declared.values.select { |parameter| parameter["required"] }.map { |parameter| parameter["name"] }
    (required - sent.keys).map { |name| "missing required query parameter #{name}" } +
      sent.flat_map do |name, texts|
        next ["undeclared query parameter #{name}"] unless declared.key?(name)

        query_value_errors(declared[name], texts)
      end
  end

  # Query values travel as text; they are read back with the parameter's type before validation. Only
  # an array parameter may repeat its key.
  def query_value_errors(parameter, texts)
    schema = OpenapiContract.resolve(parameter["schema"])
    pointer = "?#{parameter['name']}"
    if schema["type"] == "array"
      items = OpenapiContract.resolve(schema["items"])
      return OpenapiContract.validate(schema, texts.map { |text| typed(items, text) }, pointer)
    end
    return ["#{pointer}: sent #{texts.size} times"] if texts.size > 1

    OpenapiContract.validate(schema, typed(schema, texts.first), pointer)
  end

  def typed(schema, text)
    case schema["type"]
    when "integer" then Integer(text, exception: false) || text
    when "boolean" then { "true" => true, "false" => false }.fetch(text, text)
    else text
    end
  end

  def token_errors(found, request)
    token = request.headers.key?("Authorization")
    return [] if found.anonymous? != token

    [found.anonymous? ? "sends a token to an anonymous operation" : "sends no token"]
  end

  # A POST that takes no body gets `{}` from the gem, which KSeF accepts.
  def body_errors(found, request)
    body = request.body.to_s
    if found.request_content.empty?
      return body.empty? || body == "{}" ? [] : ["sends a body the operation does not take"]
    end

    content_type = request.headers["Content-Type"].to_s.split(";").first
    media = found.request_content[content_type]
    return ["sends #{content_type.inspect}, the contract takes #{found.request_content.keys}"] unless media
    return [] unless content_type == "application/json"

    OpenapiContract.validate(media["schema"], JSON.parse(body))
  end

  # Walks a list to its end; keeps what it yielded and the operations that served it.
  def walk(list)
    first = recorded.size
    items = list.to_a
    walks << { items: items, operations: recorded.drop(first).map { |request| operation_of(request)&.key } }
  end

  def bodies(key)
    recorded.select { |request| operation_of(request)&.key == key }.map { |request| JSON.parse(request.body) }
  end

  # Calls every resource method, plus the online and batch sessions, once.
  def exercise_everything
    exercise_auth
    exercise_online_and_batch
    exercise_session_reads
    exercise_invoices
    exercise_certificates_and_tokens
    exercise_permission_grants
    exercise_permission_queries
    exercise_test_data
    client.limits.context
    client.limits.subject
    client.limits.rate_limits
    walk(client.peppol.query)
  end

  def exercise_auth
    c = client
    cert, key = CertificateHelper.ec_pair
    challenge = example_response("POST /auth/challenge")
    unsigned = Ksef::Xades::AuthTokenRequest.new(challenge: challenge["challenge"], context: { nip: "5265877635" },
                                                 allowed_ips: { addresses: ["192.168.0.1"] }).to_xml
    c.auth.challenge
    c.auth.submit_xades(Ksef::Xades::Signer.new(cert: cert, key: key).sign(unsigned), verify_certificate_chain: true)
    encrypted = Ksef::Auth::KsefTokenEncryptor.new(crypto: c.crypto, public_keys: c.public_keys)
                                              .encrypt(token: "ksef-token", timestamp_ms: challenge["timestampMs"])
    c.auth.submit_ksef_token(challenge: challenge["challenge"], context_type: "Nip", context_value: "5265877635",
                             encrypted_token: encrypted.encrypted_token, public_key_id: encrypted.public_key_id)
    c.auth.status(reference, authentication_token: "authentication-token")
    c.auth.redeem(authentication_token: "authentication-token")
    c.auth.refresh(refresh_token: "refresh-token")
    walk(c.auth.sessions(page_size: 10))
    c.auth.revoke_current_session(token: "refresh-token")
    c.auth.revoke_session(reference)
    c.security.public_key_certificates
  end

  def exercise_online_and_batch
    session = Ksef::Sessions::Online.open(client)
    session.send_invoice(invoice_xml)
    session.send_invoice(invoice_xml, offline_mode: true, hash_of_corrected_invoice: corrected_hash)
    session.close
    Ksef::Batch::Uploader.new(client).call(invoices: { "invoice-1.xml" => invoice_xml }, compression: :tar_gz,
                                           offline_mode: true)
  end

  def exercise_session_reads
    c = client
    walk(c.sessions.list(session_type: "Online", reference_number: reference, statuses: %w[Succeeded Failed],
                         date_created_from: moment, date_created_to: moment, date_closed_from: moment,
                         date_closed_to: moment, date_modified_from: moment, date_modified_to: moment))
    c.sessions.status(reference)
    walk(c.sessions.invoices(reference))
    walk(c.sessions.failed_invoices(reference))
    c.sessions.invoice(reference, invoice_reference)
    c.sessions.invoice_upo(reference, invoice_reference)
    c.sessions.invoice_upo_by_ksef(reference, ksef_number)
    c.sessions.session_upo(reference, upo_reference)
  end

  def exercise_invoices
    c = client
    c.invoices.get_by_ksef_number(ksef_number)
    walk(c.invoices.query_metadata(filters: example_body("POST /invoices/query/metadata"), sort_order: "Desc"))
    c.exports.create(encryption_info: c.crypto.encryption_data.encryption_info,
                     filters: example_body("POST /invoices/exports")["filters"], only_metadata: true,
                     compression_type: "TarGz")
    c.exports.status(reference)
    numbers = c.collective_identifiers.generate(invoices: example_body("POST /collective-identifiers")["invoices"])
    walk(c.collective_identifiers.query(filters: example_body("POST /collective-identifiers/query")))
    walk(c.collective_identifiers.invoices(collective_identifier_numbers: [numbers["collectiveIdentifierNumber"]]))
    walk(c.collective_identifiers.by_ksef_number(ksef_number))
  end

  def exercise_certificates_and_tokens
    c = client
    c.certificates.limits
    csr = Ksef::Crypto::Csr.generate_ecdsa(c.certificates.enrollment_data)
    c.certificates.enroll(certificate_name: "Contract", certificate_type: "Offline", csr: csr.csr_der_base64,
                          valid_from: moment)
    c.certificates.enrollment_status(reference)
    walk(c.certificates.query(body: example_body("POST /certificates/query")))
    c.certificates.retrieve(certificate_serial_numbers: [serial])
    c.certificates.revoke(serial, revocation_reason: "KeyCompromise")
    c.tokens.generate(permissions: %w[InvoiceRead InvoiceWrite], description: "Contract")
    walk(c.tokens.list(status: %w[Active Pending], description: "Contract", author_identifier: "5265877635",
                       author_identifier_type: "Nip"))
    c.tokens.status(reference)
    c.tokens.revoke(reference)
  end

  def exercise_permission_grants
    p = client.permissions
    p.grant_persons(body: example_body("POST /permissions/persons/grants"))
    p.grant_entities(body: example_body("POST /permissions/entities/grants"))
    p.grant_authorizations(body: example_body("POST /permissions/authorizations/grants"))
    p.grant_indirect(body: example_body("POST /permissions/indirect/grants"))
    p.grant_subunits(body: example_body("POST /permissions/subunits/grants"))
    p.grant_eu_entities(body: example_body("POST /permissions/eu-entities/grants"))
    p.grant_eu_entity_administration(body: example_body("POST /permissions/eu-entities/administration/grants"))
    p.revoke_common(permission_ids[0])
    p.revoke_authorization(permission_ids[1])
    p.operation_status(reference)
  end

  def exercise_permission_queries
    p = client.permissions
    walk(p.query_persons(body: example_body("POST /permissions/query/persons/grants")))
    walk(p.query_personal(body: example_body("POST /permissions/query/personal/grants")))
    walk(p.query_entities(body: example_body("POST /permissions/query/entities/grants")))
    walk(p.query_authorizations(body: example_body("POST /permissions/query/authorizations/grants")))
    # The document's own example breaks its pattern (DE takes 9 digits, the example has 12).
    eu_query = example_body("POST /permissions/query/eu-entities/grants").merge("vatUeIdentifier" => "DE123456789")
    walk(p.query_eu_entities(body: eu_query))
    walk(p.query_subunits(body: example_body("POST /permissions/query/subunits/grants")))
    walk(p.query_entity_roles)
    walk(p.query_subordinate_entity_roles(body: example_body("POST /permissions/query/subordinate-entities/roles")))
    p.attachment_status
  end

  def exercise_test_data
    t = client.test_data
    t.create_subject(body: example_body("POST /testdata/subject"))
    t.remove_subject(body: example_body("POST /testdata/subject/remove"))
    t.create_person(body: example_body("POST /testdata/person"))
    t.remove_person(body: example_body("POST /testdata/person/remove"))
    t.grant_permissions(body: example_body("POST /testdata/permissions"))
    t.revoke_permissions(body: example_body("POST /testdata/permissions/revoke"))
    t.enable_attachment(body: example_body("POST /testdata/attachment"))
    t.disable_attachment(body: example_body("POST /testdata/attachment/revoke"))
    context = { "contextIdentifier" => { "type" => "Nip", "value" => "5265877635" } }
    t.block_context(body: context)
    t.unblock_context(body: context)
    session_limits = { "maxInvoiceSizeInMB" => 1, "maxInvoiceWithAttachmentSizeInMB" => 3, "maxInvoices" => 10 }
    t.set_session_limits(body: { "onlineSession" => session_limits, "batchSession" => session_limits,
                                 "collectiveIdentifier" => { "maxInvoices" => 10 } })
    t.reset_session_limits
    t.set_certificate_limits(body: { "subjectIdentifierType" => "Nip", "enrollment" => { "maxEnrollments" => 5 },
                                     "certificate" => { "maxCertificates" => 5 } })
    t.reset_certificate_limits
    groups = OpenapiContract.resolve(OpenapiContract.schemas["ApiRateLimitsOverride"])["required"]
    limits = { "perSecond" => 1, "perMinute" => 2, "perHour" => 3 }
    t.set_rate_limits(body: { "rateLimits" => groups.to_h { |group| [group, limits] } })
    t.reset_rate_limits
    t.set_production_rate_limits
    t.update_certificate(serial, valid_to: moment)
  end

  describe "requests" do
    before do
      stub_request(:any, /.*/).to_return(status: 201, body: "") # presigned uploads
      stub_request(:any, api).to_return do |request|
        recorded << request
        queries[request] = URI.decode_www_form(sent_queries.last.to_s)
        respond(request)
      end
      exercise_everything
    end

    it "matches the contract for every request" do
      errors = recorded.flat_map { |request| contract_errors(request) }.uniq

      expect(errors).to be_empty, errors.join("\n")
    end

    it "covers every operation and every parameter of the contract" do
      exercised = Hash.new { |hash, key| hash[key] = Set.new }
      recorded.each do |request|
        names = exercised[operation_of(request)&.key]
        names.merge(query_pairs(request).map(&:first))
        names << "x-continuation-token" if request.headers.key?("X-Continuation-Token")
      end
      missing = OpenapiContract.operations.flat_map do |found|
        next ["#{found.key} (never called)"] unless exercised.key?(found.key)

        (found.parameters("query") + found.parameters("header")).map { |parameter| parameter["name"] }
                                                                .reject { |name| exercised[found.key].include?(name) }
                                                                .map { |name| "#{found.key} ?#{name}" }
      end

      expect(missing).to be_empty, missing.join("\n")
    end

    it "walks every list to its second page and yields the items of both" do
      problems = walks.map do |walk|
        key = walk[:operations].first
        next "a list sent no request" unless key

        expected = example_response(key).then { |page| page[items_key(page)] * 2 }
        next if walk[:operations] == [key, key] && walk[:items] == expected

        "#{key}: #{walk[:operations].size} requests yielded #{walk[:items].size} items, " \
          "expected 2 and #{expected.size}"
      end
      lists = OpenapiContract.operations.select { |found| paginated?(found) }.map(&:key)
      unwalked = (lists - walks.map { |walk| walk[:operations].first }).map { |key| "#{key}: never walked" }
      errors = paging_errors + problems.compact + unwalked

      expect(errors).to be_empty, errors.join("\n")
    end

    it "puts every argument into its own path segment" do
      expected = {
        "GET /sessions/{referenceNumber}/invoices/{invoiceReferenceNumber}" => [reference, invoice_reference],
        "GET /sessions/{referenceNumber}/invoices/{invoiceReferenceNumber}/upo" => [reference, invoice_reference],
        "GET /sessions/{referenceNumber}/invoices/ksef/{ksefNumber}/upo" => [reference, ksef_number],
        "GET /sessions/{referenceNumber}/upo/{upoReferenceNumber}" => [reference, upo_reference],
        "DELETE /permissions/common/grants/{permissionId}" => [permission_ids[0]],
        "DELETE /permissions/authorizations/grants/{permissionId}" => [permission_ids[1]],
        "POST /certificates/{certificateSerialNumber}/revoke" => [serial]
      }
      sent = expected.to_h do |key, values|
        requests = recorded.select { |request| operation_of(request)&.key == key }
        [key, requests.map { |request| path_values(request).values }.find { |found| found == values }]
      end

      expect(sent).to eq(expected)
    end

    it "sends the options the caller passed" do
      online = bodies("POST /sessions/online/{referenceNumber}/invoices")
      token_key = public_keys.find { |key| key["usage"].include?("KsefTokenEncryption") }["publicKeyId"]

      expect(online.map { |body| body.values_at("offlineMode", "hashOfCorrectedInvoice") })
        .to eq([[false, nil], [true, corrected_hash]])
      expect(bodies("POST /sessions/batch").map { |body| body["offlineMode"] }).to eq([true])
      expect(bodies("POST /invoices/exports").map { |body| body.values_at("onlyMetadata", "compressionType") })
        .to eq([[true, "TarGz"]])
      expect(bodies("POST /auth/ksef-token").map { |body| body["publicKeyId"] }).to eq([token_key])
      expect(bodies("POST /certificates/{certificateSerialNumber}/revoke"))
        .to eq([{ "revocationReason" => "KeyCompromise" }])
      sessions = recorded.find { |request| operation_of(request)&.key == "GET /sessions" }
      expect(query_pairs(sessions).filter_map { |name, value| value if name == "statuses" }).to eq(%w[Succeeded Failed])
    end
  end

  # Fields the gem reads from responses (lib/), as dotted paths into the 2xx JSON schema.
  reads = {
    "POST /auth/challenge" => %w[challenge timestampMs],
    "POST /auth/xades-signature" => %w[referenceNumber authenticationToken.token],
    "POST /auth/ksef-token" => %w[referenceNumber authenticationToken.token],
    "GET /auth/{referenceNumber}" => %w[status.code status.description status.details],
    "POST /auth/token/redeem" => %w[accessToken.token accessToken.validUntil refreshToken.token
                                    refreshToken.validUntil],
    "POST /auth/token/refresh" => %w[accessToken.token accessToken.validUntil],
    "GET /auth/sessions" => %w[items continuationToken],
    "GET /security/public-key-certificates" => %w[[].certificate [].certificateId [].publicKeyId [].validFrom
                                                  [].validTo [].usage],
    "POST /sessions/online" => %w[referenceNumber],
    "POST /sessions/online/{referenceNumber}/invoices" => %w[referenceNumber],
    "POST /sessions/batch" => %w[referenceNumber partUploadRequests.[].ordinalNumber partUploadRequests.[].method
                                 partUploadRequests.[].url partUploadRequests.[].headers],
    "GET /sessions" => %w[sessions continuationToken],
    "GET /sessions/{referenceNumber}" => %w[status.code upo.pages.[].referenceNumber],
    "GET /sessions/{referenceNumber}/invoices" => %w[invoices continuationToken],
    "GET /sessions/{referenceNumber}/invoices/failed" => %w[invoices continuationToken],
    "GET /sessions/{referenceNumber}/invoices/{invoiceReferenceNumber}" =>
      %w[status.code status.description ksefNumber],
    "POST /invoices/query/metadata" => %w[invoices hasMore isTruncated],
    "POST /invoices/exports" => %w[referenceNumber],
    "GET /invoices/exports/{referenceNumber}" => %w[status.code status.description package.parts.[].ordinalNumber
                                                    package.parts.[].method package.parts.[].url
                                                    package.parts.[].encryptedPartHash package.compressionType
                                                    package.isTruncated
                                                    package.lastPermanentStorageDate package.permanentStorageHwmDate
                                                    package.invoiceCount],
    "POST /collective-identifiers" => %w[collectiveIdentifierNumber],
    "POST /collective-identifiers/query" => %w[collectiveIdentifiers continuationToken],
    "POST /collective-identifiers/invoices" => %w[invoices continuationToken],
    "GET /collective-identifiers/ksef/{ksefNumber}" => %w[collectiveIdentifiers continuationToken],
    "GET /certificates/enrollments/data" => Ksef::Crypto::Csr::SUBJECT_FIELDS.map { |_oid, field, _type| field },
    "POST /certificates/enrollments" => %w[referenceNumber],
    "GET /certificates/enrollments/{referenceNumber}" => %w[status.code certificateSerialNumber],
    "POST /certificates/query" => %w[certificates hasMore],
    "POST /certificates/retrieve" => %w[certificates.[].certificate],
    "POST /tokens" => %w[referenceNumber token],
    "GET /tokens" => %w[tokens continuationToken],
    "POST /permissions/query/persons/grants" => %w[permissions hasMore],
    "POST /permissions/query/personal/grants" => %w[permissions hasMore],
    "POST /permissions/query/entities/grants" => %w[permissions hasMore],
    "POST /permissions/query/eu-entities/grants" => %w[permissions hasMore],
    "POST /permissions/query/subunits/grants" => %w[permissions hasMore],
    "POST /permissions/query/authorizations/grants" => %w[authorizationGrants hasMore],
    "GET /permissions/query/entities/roles" => %w[roles hasMore],
    "POST /permissions/query/subordinate-entities/roles" => %w[roles hasMore],
    "GET /peppol/query" => %w[peppolProviders hasMore]
  }.freeze

  it "describes every response field the gem reads" do
    missing = reads.flat_map do |key, fields|
      status = operation(key).definition["responses"].keys.find { |code| code.start_with?("2") }
      schema = operation(key).response_schema(status)
      fields.reject { |field| OpenapiContract.field?(schema, field) }.map { |field| "#{key} → #{field}" }
    end

    expect(missing).to be_empty, missing.join("\n")
  end

  it "describes the error fields Http::ErrorParser reads, in both formats" do
    online = operation("POST /sessions/online")
    expectations = {
      online.response_schema(400, "application/problem+json") => %w[title detail traceId errors.[].code],
      online.response_schema(400) => %w[exception.referenceNumber exception.exceptionDetailList.[].exceptionCode
                                        exception.exceptionDetailList.[].exceptionDescription],
      online.response_schema(403, "application/problem+json") => %w[detail reasonCode traceId],
      online.response_schema(429) => %w[status.code status.description status.details]
    }
    missing = expectations.flat_map { |schema, fields| fields.reject { |field| OpenapiContract.field?(schema, field) } }

    expect(missing).to be_empty
  end

  it "uses only enum values the contract defines" do
    enum = ->(name) { OpenapiContract.resolve(OpenapiContract.schemas.fetch(name))["enum"] }
    query_enum = lambda do |key, name|
      parameter = operation(key).parameters("query").find { |candidate| candidate["name"] == name }
      OpenapiContract.resolve(parameter["schema"])["enum"]
    end

    expect(enum.call("CompressionType")).to match_array(Ksef::Invoices::Export::COMPRESSION_TYPES)
    expect(Ksef::Batch::Uploader::COMPRESSION_TYPES.values).to match_array(enum.call("CompressionType"))
    expect(query_enum.call("GET /sessions", "sessionType")).to match_array(Ksef::Resources::Sessions::SESSION_TYPES)
    expect(query_enum.call("POST /invoices/query/metadata", "sortOrder"))
      .to match_array(Ksef::Resources::Invoices::SORT_ORDERS)
    expect(enum.call("KsefCertificateType")).to match_array(%w[Authentication Offline])
    expect(enum.call("PublicKeyCertificateUsage"))
      .to include(Ksef::Crypto::PublicKeys::SYMMETRIC_KEY_ENCRYPTION, Ksef::Crypto::PublicKeys::KSEF_TOKEN_ENCRYPTION)
    expect(enum.call("AuthenticationContextIdentifierType"))
      .to match_array(Ksef::Auth::Coordinator::CONTEXT_TYPES.values)
    # SubjectAuthorized is left out on purpose.
    expect(enum.call("InvoiceQuerySubjectType")).to include(*Ksef::Sync::Incremental::SUBJECT_TYPES)
  end

  # Sync::Incremental never runs in the request flow above (it needs a downloadable package), so the
  # filters it builds (dateType, subject types, open and closed windows) are checked on their own.
  it "builds Sync::Incremental export filters the contract accepts" do
    export = instance_double(Ksef::Invoices::Export)
    sent = []
    allow(Ksef::Invoices::Export).to receive(:new).and_return(export)
    allow(export).to receive(:call) do |filters:, **|
      sent << filters
      nil
    end
    runs = Ksef::Sync::Incremental::SUBJECT_TYPES.map { |type| { subject_type: type } } + [{}]
    [Time.now - 3600, Time.now - (91 * 86_400)].product(runs).each do |from, options|
      Ksef::Sync::Incremental.new(test_client, from: from, **options).each_invoice { nil }
    end
    schema = OpenapiContract.resolve(operation("POST /invoices/exports").request_content["application/json"]["schema"])
    errors = sent.flat_map { |filters| OpenapiContract.validate(schema["properties"]["filters"], filters, "filters") }

    expect(sent.size).to eq(runs.size * 2)
    expect(sent.map { |filters| filters["dateRange"].key?("to") }.uniq).to contain_exactly(true, false)
    expect(errors).to be_empty, errors.join("\n")
  end

  it "lists every Ksef::FormCode in the form-code table of an online session" do
    table = OpenapiContract.schemas["OpenOnlineSessionRequest"]["properties"]["formCode"]["description"]
    forms = [Ksef::FormCode::FA2, Ksef::FormCode::FA3, Ksef::FormCode::PEF3, Ksef::FormCode::PEF_KOR3,
             Ksef::FormCode::FA_RR1]
    rows = forms.reject do |form|
      table.match?(/\[#{Regexp.escape(form.system_code)}\][^|]*\| #{form.schema_version} \| #{form.value} \|/)
    end

    expect(rows.map(&:system_code)).to be_empty
  end

  it "documents the business and status codes the gem reacts to where it reacts to them" do
    description = ->(key) { operation(key).definition.to_json }

    expect(description.call("POST /sessions/online")).to include("21470")
    expect(description.call("POST /sessions/online/{referenceNumber}/invoices")).to include("21184")
    %w[21301 21304 21308].each do |code|
      expect(description.call("POST /auth/token/refresh")).to include(code)
      expect(description.call("POST /auth/token/redeem")).to include(code)
    end
    expect(OpenapiContract.schemas["InvoiceExportStatusResponse"].to_json).to include("| 210 |")
    expect(OpenapiContract.schemas.to_json).to include("Duplikat faktury")
  end
end
