# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ksef::Http::ErrorParser do
  describe ".build_error" do
    it "maps the HTTP status onto the right exception class" do
      expect(described_class.build_error(status: 400, body: {}, headers: {})).to be_a(Ksef::BadRequest)
      expect(described_class.build_error(status: 401, body: {}, headers: {})).to be_a(Ksef::Unauthorized)
      expect(described_class.build_error(status: 403, body: {}, headers: {})).to be_a(Ksef::Forbidden)
      expect(described_class.build_error(status: 410, body: {}, headers: {})).to be_a(Ksef::Gone)
      expect(described_class.build_error(status: 500, body: {}, headers: {})).to be_a(Ksef::ServerError)
    end

    it "parses the legacy exception.exceptionDetailList[] format" do
      body = {
        "exception" => {
          "referenceNumber" => "ABC-123",
          "exceptionDetailList" => [
            { "exceptionCode" => 21_402, "exceptionDescription" => "Invalid size" }
          ]
        }
      }
      error = described_class.build_error(status: 400, body: body, headers: {})
      expect(error).to be_a(Ksef::BadRequest)
      expect(error.codes).to eq([21_402])
      expect(error.trace_id).to eq("ABC-123")
      expect(error.message).to include("Invalid size")
    end

    it "parses the RFC 7807 problem-details format" do
      body = {
        "title" => "Bad Request",
        "status" => 400,
        "detail" => "Validation failed",
        "traceId" => "trace-9",
        "errors" => [{ "code" => 21_403, "description" => "Invalid digest" }]
      }
      error = described_class.build_error(status: 400, body: body, headers: {})
      expect(error.codes).to eq([21_403])
      expect(error.trace_id).to eq("trace-9")
      expect(error.message).to include("Validation failed")
    end

    it "adds each problem-details error's description and details to the generic detail" do
      body = { "title" => "Bad Request", "status" => 400, "detail" => "Żądanie jest nieprawidłowe.",
               "errors" => [{ "code" => 21_405, "description" => "Błąd walidacji danych wejściowych.",
                              "details" => ["Wskazany kod formularza nie jest wspierany."] }] }

      expect(described_class.build_error(status: 400, body: body, headers: {}).message)
        .to include("Żądanie jest nieprawidłowe. — Błąd walidacji danych wejściowych. " \
                    "(Wskazany kod formularza nie jest wspierany.)")
    end

    it "keeps a non-JSON body as a short UTF-8 excerpt" do
      page = "<html><title>502 Bad Gateway</title>#{' ' * 50}#{'x' * 1000}</html>".b
      error = described_class.build_error(status: 502, body: page, headers: {})

      expect(error.message.encoding).to eq(Encoding::UTF_8)
      expect(error.message).to include("<html><title>502 Bad Gateway</title> x")
      expect(error.body["message"].length).to eq(described_class::EXCERPT_LENGTH + 1)
    end

    it "falls back to the legacy serviceCode (a traceparent) when referenceNumber is null" do
      body = { "exception" => { "referenceNumber" => nil, "serviceCode" => "00-c02cc3747020c605-01",
                                "exceptionDetailList" => [{ "exceptionCode" => 21_402 }] } }

      expect(described_class.build_error(status: 400, body: body, headers: {}).trace_id).to eq("00-c02cc3747020c605-01")
    end

    it "fills in retry_after for a 429 from the Retry-After header" do
      error = described_class.build_error(status: 429, body: {}, headers: { "Retry-After" => "30" })
      expect(error).to be_a(Ksef::RateLimited)
      expect(error.retry_after).to eq(30)
    end

    it "raises SessionUnavailable (still a BadRequest) for a session under maintenance (21184)" do
      body = { "title" => "Bad Request", "errors" => [{ "code" => 21_184, "description" => "Sesja niedostępna" }] }
      error = described_class.build_error(status: 400, body: body, headers: {})

      expect(error).to be_a(Ksef::SessionUnavailable)
      expect(error).to be_a(Ksef::BadRequest)
      expect(described_class.build_error(status: 500, body: body, headers: {})).to be_an_instance_of(Ksef::ServerError)
    end

    it "raises ReauthenticationRequired for 21301 and 21304, and a plain BadRequest for 21308 (deceased person)" do
      [21_301, 21_304].each do |code|
        body = { "detail" => "Brak autoryzacji.", "errors" => [{ "code" => code, "description" => "Odmowa" }] }

        expect(described_class.build_error(status: 400, body: body, headers: {}))
          .to be_a(Ksef::ReauthenticationRequired), code.to_s
      end
      body = { "errors" => [{ "code" => 21_308, "description" => "Osoba zmarła" }] }
      expect(described_class.build_error(status: 400, body: body, headers: {})).to be_an_instance_of(Ksef::BadRequest)
      expect(described_class.build_error(status: 403, body: { "errors" => [{ "code" => 21_301 }] }, headers: {}))
        .to be_an_instance_of(Ksef::Forbidden)
    end

    it "builds an ApiError from a malformed legacy body instead of raising" do
      ["x", 1, nil].each do |entry|
        body = { "exception" => { "exceptionDetailList" => [entry, { "exceptionCode" => 21_405 }] } }

        expect(described_class.build_error(status: 400, body: body, headers: {}).codes).to eq([21_405])
      end
      expect(described_class.build_error(status: 400, body: { "exception" => { "exceptionDetailList" => "x" } },
                                         headers: {})).to be_a(Ksef::BadRequest)
    end

    it "parses the legacy 429 body { status: { code, description, details } }" do
      body = { "status" => { "code" => 429, "description" => "Too many requests", "details" => ["try in 30 s"] } }
      error = described_class.build_error(status: 429, body: body, headers: { "Retry-After" => "30" })

      expect(error.message).to include("Too many requests")
      expect(error.codes).to eq([429])
      expect(error.details).to eq(["try in 30 s"])
    end

    it "keeps the reasonCode of a 403 problem-details body in the message" do
      body = { "title" => "Forbidden", "status" => 403, "detail" => "Brak uprawnień.",
               "reasonCode" => "missing-permissions" }

      expect(described_class.build_error(status: 403, body: body, headers: {}).message)
        .to include("Brak uprawnień. (missing-permissions)")
    end

    it "parses a raw JSON string" do
      error = described_class.build_error(status: 400, body: '{"title":"X","errors":[{"code":11}]}', headers: {})
      expect(error.codes).to eq([11])
    end
  end
end
