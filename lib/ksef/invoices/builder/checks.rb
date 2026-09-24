# frozen_string_literal: true

module Ksef
  module Invoices
    class Builder
      # The checks {Builder#to_xml} runs before rendering: required values, numbers, codes and text.
      # @api private
      module Checks
        # Rates with VAT, which a foreign-currency invoice would also have to state in PLN (`P_14_xW`).
        VAT_RATES = %w[23 8 5].freeze

        private

        def check!
          check_parties!
          raise ConfigurationError, "at least one line is required" if lines.empty?

          check_required!(number: number, issue_date: issue_date)
          check_codes!
          check_lines!
          check_tax!
          check_correction!
          check_payment!
          check_text!
        end

        def check_parties!
          raise ConfigurationError, "seller and buyer are required" unless seller && buyer

          check_required!("seller name": seller.name, "seller address": seller.address,
                          "buyer name": buyer.name, "buyer address": buyer.address)
          id_type = buyer.id_type.to_s
          unless id_type.empty? || BUYER_ID_TYPES.include?(id_type)
            raise ConfigurationError, "Unknown buyer id_type: #{id_type}"
          end
          return unless %w[eu other].include?(buyer.identification) && blank?(buyer.country)

          raise ConfigurationError, "buyer country is required for a buyer identified by id_type " \
                                    "#{buyer.identification.inspect} (Adres/KodKraju)"
        end

        def check_required!(**values)
          missing = values.select { |_, value| blank?(value) }.keys
          raise ConfigurationError, "#{missing.join(', ')} required" unless missing.empty?
        end

        def check_codes!
          unknown = annotations.map(&:to_sym) - ANNOTATIONS.keys
          raise ConfigurationError, "Unknown annotation(s): #{unknown.join(', ')}" unless unknown.empty?
          raise ConfigurationError, "Unknown invoice_type: #{invoice_type}" unless INVOICE_TYPES.include?(invoice_type)
          unless blank?(correction_type) || CORRECTION_TYPES.include?(correction_type.to_s)
            raise ConfigurationError, "Unknown correction_type: #{correction_type}"
          end
          raise ConfigurationError, "Unknown currency: #{currency}" unless CURRENCY.match?(currency.to_s)

          [seller, buyer].each do |party|
            next if blank?(party.country) || COUNTRY.match?(party.country.to_s)

            raise ConfigurationError, "Unknown country: #{party.country.inspect} (an ISO 3166 code such as \"DE\")"
          end
        end

        def check_lines!
          unknown_rates = lines.map(&:rate).uniq - RATES.keys
          raise ConfigurationError, "Unknown VAT rate(s): #{unknown_rates.join(', ')}" unless unknown_rates.empty?

          lines.each.with_index(1) do |line, index|
            line.net
            next if blank?(line.gtu) || GTU_CODES.include?(line.gtu.to_s)

            raise ConfigurationError, "Unknown GTU code: #{line.gtu} (GTU_01 … GTU_13)"
          rescue ConfigurationError => e
            raise ConfigurationError, "line #{index}: #{e.message}"
          end
        end

        def check_tax!
          if exempt? && blank?(exemption_reason)
            raise ConfigurationError, "exemption_reason is required for a zw line — the legal basis of the " \
                                      "exemption (P_19A), e.g. \"art. 113 ust. 1 ustawy o VAT\""
          end
          return if currency == "PLN" || lines.none? { |line| VAT_RATES.include?(line.rate) }

          raise ConfigurationError, "a #{currency} invoice with a 23/8/5% line must also state the VAT in PLN " \
                                    "(P_14_xW), which the builder does not write — issue it in PLN"
        end

        def check_correction!
          return unless correction?

          check_required!(corrected_date: corrected_date, corrected_number: corrected_number)
        end

        def check_payment!
          payment_code
          flag = paid_flag
          raise ConfigurationError, "paid_date is required when paid is true" if flag && blank?(paid_date)
          raise ConfigurationError, "paid_date is given but paid is not true" if !flag && !blank?(paid_date)
          raise ConfigurationError, "bank_name needs bank_account" if blank?(bank_account) && !blank?(bank_name)
        end

        # Every String that ends up in the XML: valid UTF-8, no character XML or KSeF refuses.
        def check_text!
          texts = to_h.except(:seller, :buyer, :lines).map { |name, value| [name.to_s, value] }
          { "seller" => seller, "buyer" => buyer }.each do |role, party|
            texts.concat(party.to_h.map { |name, value| ["#{role} #{name}", value] })
          end
          lines.each.with_index(1) do |line, index|
            texts.concat(line.to_h.map { |name, value| ["line #{index} #{name}", value] })
          end
          texts.each { |label, value| check_string!(label, value) if value.is_a?(String) }
        end

        def check_string!(label, value)
          unless [Encoding::UTF_8, Encoding::US_ASCII].include?(value.encoding) && value.valid_encoding?
            raise ConfigurationError, "#{label} is not a UTF-8 String (#{value.encoding}) — " \
                                      "convert it with String#encode(\"UTF-8\")"
          end
          bad = value[XML_DISALLOWED] || value[Validator::DISALLOWED_CHARACTERS]
          return unless bad

          raise ConfigurationError, "#{label} contains #{format('U+%04X', bad.ord)}, a character KSeF refuses"
        end
      end
    end
  end
end
