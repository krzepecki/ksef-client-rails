# frozen_string_literal: true

require "bigdecimal"
require "date"
require "nokogiri"
require "ksef/invoices/builder/checks"
require "ksef/invoices/builder/number"

module Ksef
  module Invoices
    # Builds an FA(3) invoice: parties, lines with their VAT rates, payment, annotations, a correction,
    # footer. Elements follow the schema sequence; the summary per rate is computed from the lines, and
    # input the builder cannot render correctly is refused with ConfigurationError rather than guessed.
    class Builder
      include Checks

      # Rate (the `P_12` value) → its summary fields and percentage, in schema order. Rates without VAT
      # have no `P_14_x` field.
      RATES = {
        "23" => { net: "P_13_1", vat: "P_14_1", percent: 23 },
        "8" => { net: "P_13_2", vat: "P_14_2", percent: 8 },
        "5" => { net: "P_13_3", vat: "P_14_3", percent: 5 },
        "0 KR" => { net: "P_13_6_1", percent: 0 },
        "0 WDT" => { net: "P_13_6_2", percent: 0 },
        "0 EX" => { net: "P_13_6_3", percent: 0 },
        "zw" => { net: "P_13_7", percent: 0 },
        "np I" => { net: "P_13_8", percent: 0 },
        "np II" => { net: "P_13_9", percent: 0 },
        "oo" => { net: "P_13_10", percent: 0 }
      }.freeze

      # `FormaPlatnosci` codes; a symbol may stand for the code.
      PAYMENT_METHODS = { cash: "1", card: "2", voucher: "3", cheque: "4", credit: "5", transfer: "6",
                          mobile: "7" }.freeze

      # `Adnotacje` flags set to 1 by {#annotations}; every other one is 2. `reverse_charge` is also set
      # by an `oo` or `np II` line, and `P_19` (exemption) by a `zw` line.
      ANNOTATIONS = { cash_method: "P_16", self_billing: "P_17", reverse_charge: "P_18", split_payment: "P_18A",
                      triangular: "P_23" }.freeze

      # Rates whose tax the buyer settles (`P_18` = 1).
      REVERSE_CHARGE_RATES = ["oo", "np II"].freeze

      INVOICE_TYPES = %w[VAT KOR].freeze
      CORRECTION_TYPES = %w[1 2 3].freeze
      GTU_CODES = (1..13).map { |i| format("GTU_%02d", i) }.freeze

      # Code formats; the schema's enumerations are checked when the XML is validated.
      COUNTRY = /\A[A-Z]{2}\z/
      CURRENCY = /\A[A-Z]{3}\z/
      # Characters XML 1.0 does not allow.
      XML_DISALLOWED = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/

      # `Podmiot2/DaneIdentyfikacyjne`: a Polish NIP, an EU VAT number, another tax ID, or none (a consumer).
      BUYER_ID_TYPES = %w[nip eu other none].freeze

      PARTY_FIELDS = %i[nip name address country email phone id_type eu_code vat_eu id_number].freeze
      LINE_FIELDS = %i[name unit quantity unit_price rate index gtin pkwiu cn gtu discount].freeze

      # A seller or buyer. `id_type` (one of {BUYER_ID_TYPES}) applies to the buyer; without it a party
      # with a NIP is identified by it, one without by none.
      Party = Struct.new(*PARTY_FIELDS, keyword_init: true) do
        # @return [String] one of {BUYER_ID_TYPES}
        def identification
          return id_type.to_s if BUYER_ID_TYPES.include?(id_type.to_s)

          nip.to_s.strip.empty? ? "none" : "nip"
        end
      end

      # An invoice line. `quantity` and `unit_price` are required; numbers are Integers, BigDecimals or
      # Strings with a comma or a dot ("1234,56", "1 234,56"). Prices and discounts take at most 2 decimal
      # places, quantities 6; anything else raises ConfigurationError.
      Line = Struct.new(*LINE_FIELDS, keyword_init: true) do
        # @return [BigDecimal] quantity × net price, minus a discount not already in the price (`P_10`)
        # @raise [Ksef::ConfigurationError] for a missing or malformed number
        def net
          value = number(:quantity) * number(:unit_price)
          value -= number(:discount) if discount?
          value.round(2, BigDecimal::ROUND_HALF_UP)
        end

        # @return [Boolean] whether the line has a discount (`P_10`)
        def discount?
          !discount.nil? && !discount.to_s.strip.empty?
        end

        # @api private
        # @param field [Symbol] :quantity, :unit_price or :discount
        # @return [BigDecimal]
        # @raise [Ksef::ConfigurationError]
        def number(field)
          Number.parse(public_send(field), field.to_s, places: field == :quantity ? 6 : 2)
        end
      end

      ATTRIBUTES = %i[number issue_date sale_date place currency seller buyer lines payment_method due_date
                      bank_account bank_name paid paid_date exemption_reason invoice_type correction_reason
                      correction_type corrected_date corrected_number corrected_ksef_number annotations footer
                      krs regon bdo system_info].freeze

      # @!attribute [rw] number
      #   @return [String] invoice number (`P_2`); KSeF refuses a second invoice with the same seller NIP,
      #   invoice type and number
      # @!attribute [rw] seller
      #   @return [Party] `Podmiot1` — the session's context needs the permission to invoice for its NIP
      # @!attribute [rw] lines
      #   @return [Array<Line>]
      attr_accessor(*(ATTRIBUTES - %i[seller buyer lines]))
      attr_reader :seller, :buyer, :lines

      # @param attributes [Hash] any of {ATTRIBUTES}: `seller:`/`buyer:` as a Hash or {Party}, `lines:` as
      #   Hashes or {Line}s, dates as Date or "YYYY-MM-DD", `annotations:` as keys of {ANNOTATIONS},
      #   `payment_method:` as a code or a key of {PAYMENT_METHODS}, `invoice_type:` "VAT" (default) or "KOR".
      #   A KOR's lines are the change: the totals are summed from them, so give difference rows (e.g.
      #   quantity 2 at -10.00 for a 20.00 reduction) or the original row negated plus the corrected row.
      # @raise [Ksef::ConfigurationError] for an unknown attribute
      def initialize(**attributes)
        unknown = attributes.keys - ATTRIBUTES
        raise ConfigurationError, "Unknown invoice attribute(s): #{unknown.join(', ')}" unless unknown.empty?

        attributes.each { |name, value| public_send(:"#{name}=", value) }
        self.currency = "PLN" if blank?(currency)
        self.lines ||= []
        self.annotations ||= []
        self.invoice_type = "VAT" if blank?(invoice_type)
        self.system_info ||= "ksef-client-rails"
      end

      # @param value [Hash, Party]
      def seller=(value)
        @seller = party(value)
      end

      # @param value [Hash, Party]
      def buyer=(value)
        @buyer = party(value)
      end

      # @param value [Array<Hash, Line>]
      def lines=(value)
        @lines = Array(value).map { |line| line.is_a?(Line) ? line : line(line) }
      end

      # @return [Hash{String=>Hash}] rate => { net:, vat: } for the rates in use
      def totals_by_rate
        lines.group_by(&:rate).to_h do |rate, group|
          net = group.sum(BigDecimal("0"), &:net)
          [rate, { net: net, vat: (net * rate_fields(rate)[:percent] / 100).round(2, BigDecimal::ROUND_HALF_UP) }]
        end
      end

      # @return [BigDecimal]
      def net_total = totals_by_rate.values.sum(BigDecimal("0")) { |t| t[:net] }
      # @return [BigDecimal]
      def vat_total = totals_by_rate.values.sum(BigDecimal("0")) { |t| t[:vat] }
      # @return [BigDecimal]
      def gross_total = net_total + vat_total

      # @return [Boolean]
      def correction? = invoice_type == "KOR"

      # @param key [Symbol, String] a key of {ANNOTATIONS}
      # @return [Boolean] whether the flag is 1 — given in {#annotations}, or `reverse_charge` implied by a line
      def annotation?(key)
        return true if annotations.map(&:to_sym).include?(key.to_sym)

        key.to_sym == :reverse_charge && lines.any? { |line| REVERSE_CHARGE_RATES.include?(line.rate.to_s) }
      end

      # @return [Boolean] whether a line is VAT-exempt (`zw`), which sets `P_19`
      def exempt?
        lines.any? { |line| line.rate == "zw" }
      end

      # @return [Hash{Symbol=>Object}] every attribute, e.g. to start another invoice from this one
      def to_h
        ATTRIBUTES.to_h { |name| [name, public_send(name)] }
      end

      # @param created_at [Time] `DataWytworzeniaFa`
      # @return [String] FA(3) XML
      # @raise [Ksef::ConfigurationError] for a missing required value, a malformed number, an unknown code
      #   (NIP, rate, GTU, country, currency, payment method, buyer identification, annotation, invoice or
      #   correction type), a date that is not a Date / "YYYY-MM-DD", text KSeF refuses, or an invoice the
      #   builder cannot express (foreign-currency VAT, a `zw` line without `exemption_reason`)
      # @raise [Ksef::SchemaValidationError] when the result still does not match the FA(3) schema (e.g. a
      #   value over its length limit)
      def to_xml(created_at: Time.now)
        check!
        xml = Xml.new(self).render(created_at)
        Validator.new(form_code: FormCode::FA3).validate!(xml)
        xml
      end

      # @api private
      # @return [String, nil] the `FormaPlatnosci` code
      # @raise [Ksef::ConfigurationError] for an unknown method
      def payment_code
        return nil if blank?(payment_method)

        code = PAYMENT_METHODS.fetch(payment_method.to_s.to_sym, payment_method.to_s)
        raise ConfigurationError, "Unknown payment_method: #{payment_method}" unless PAYMENT_METHODS.value?(code)

        code
      end

      # @api private
      # @return [Boolean, nil] the `paid` flag: true, false, or nil when not given
      # @raise [Ksef::ConfigurationError] for a value that is not a boolean, "1"/"0" or "true"/"false"
      def paid_flag
        return nil if blank?(paid)
        return paid if [true, false].include?(paid)

        { "1" => true, "true" => true, "0" => false, "false" => false }.fetch(paid.to_s.strip.downcase) do
          raise ConfigurationError, "paid must be true or false, not #{paid.inspect}"
        end
      end

      private

      def party(value)
        return value if value.nil? || value.is_a?(Party)

        attrs = value.to_h.transform_keys(&:to_sym)
        unknown = attrs.keys - PARTY_FIELDS
        raise ConfigurationError, "Unknown party field(s): #{unknown.join(', ')}" unless unknown.empty?

        Party.new(**attrs)
      end

      def line(value)
        attrs = value.to_h.transform_keys(&:to_sym)
        unknown = attrs.keys - LINE_FIELDS
        raise ConfigurationError, "Unknown line field(s): #{unknown.join(', ')}" unless unknown.empty?

        Line.new(**attrs)
      end

      def rate_fields(rate)
        RATES.fetch(rate.to_s) { raise ConfigurationError, "Unknown VAT rate: #{rate}" }
      end

      def blank?(value)
        value.to_s.strip.empty?
      end
    end
  end
end

require "ksef/invoices/builder/xml"
