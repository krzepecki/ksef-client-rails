# frozen_string_literal: true

module Ksef
  # Invoice schema code. The { systemCode, schemaVersion, value } object
  # passed when opening a session.
  #
  # FA(2) is available on TEST only — the gem defaults to FA(3).
  class FormCode
    # @return [String] system code (e.g. "FA (3)")
    attr_reader :system_code
    # @return [String] schema version (e.g. "1-0E")
    attr_reader :schema_version
    # @return [String] value (e.g. "FA")
    attr_reader :value
    # @return [String, nil] XML namespace of the invoice document (the schema's targetNamespace);
    #   nil for PEF, whose UBL schemas are not packaged
    attr_reader :namespace

    # @param system_code [String]
    # @param schema_version [String]
    # @param value [String]
    # @param namespace [String, nil]
    def initialize(system_code:, schema_version:, value:, namespace: nil)
      @system_code = system_code
      @schema_version = schema_version
      @value = value
      @namespace = namespace
    end

    # @return [Hash] JSON representation matching the API contract
    def to_h
      { "systemCode" => system_code, "schemaVersion" => schema_version, "value" => value }
    end

    # FA(2) — TEST environment only.
    FA2 = new(system_code: "FA (2)", schema_version: "1-0E", value: "FA",
              namespace: "http://crd.gov.pl/wzor/2023/06/29/12648/")
    # FA(3) — the default production schema.
    FA3 = new(system_code: "FA (3)", schema_version: "1-0E", value: "FA",
              namespace: "http://crd.gov.pl/wzor/2025/06/25/13775/")
    # PEF(3) — PEF invoices.
    PEF3 = new(system_code: "PEF (3)", schema_version: "2-1", value: "PEF")
    # PEF_KOR(3) — PEF corrections.
    PEF_KOR3 = new(system_code: "PEF_KOR (3)", schema_version: "2-1", value: "PEF")
    # FA_RR(1) — RR invoices (flat-rate farmers).
    FA_RR1 = new(system_code: "FA_RR (1)", schema_version: "1-1E", value: "FA_RR",
                 namespace: "http://crd.gov.pl/wzor/2026/03/06/14189/")
  end
end
