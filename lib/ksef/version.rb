# frozen_string_literal: true

module Ksef
  # Gem version. Tracks compatibility with the KSeF API contract version below.
  VERSION = "1.0.0"

  # KSeF API contract version this gem targets — the OpenAPI document in spec/fixtures/openapi/,
  # which the contract suite checks every request against. Bumped together with that file (see
  # api-changelog.md in CIRFMF/ksef-api).
  API_VERSION = "2.8.1"
end
