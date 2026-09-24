# frozen_string_literal: true

require "bigdecimal"

module Ksef
  module Invoices
    class Builder
      # Reads and writes the builder's numbers exactly — never through Float.
      # @api private
      module Number
        DECIMAL = /\A[+-]?\d+(?:[.,]\d+)?\z/
        # Thousands grouped by a space, a no-break space or a narrow no-break space: "1 234,56".
        GROUPED = /\A[+-]?\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?\z/

        module_function

        # @param value [Integer, BigDecimal, Float, String, nil]
        # @param field [String] the name used in the error message
        # @param places [Integer] the most decimal places allowed
        # @return [BigDecimal]
        # @raise [Ksef::ConfigurationError] for a blank, malformed or non-finite value, or more decimal places
        def parse(value, field, places:)
          text = canonical(value)
          raise ConfigurationError, "#{field} is required" if text.nil?
          raise ConfigurationError, "#{field} is not a decimal number: #{value.inspect}" unless DECIMAL.match?(text)

          number = BigDecimal(text.tr(",", "."))
          unless number.round(places) == number
            raise ConfigurationError, "#{field} has more than #{places} decimal places: #{value.inspect}"
          end

          number
        end

        # @param value [BigDecimal]
        # @return [String] the amount with 2 decimal places, rounded half up ("100.00", "-0.50")
        def amount(value)
          rounded = value.round(2, BigDecimal::ROUND_HALF_UP)
          rounded = BigDecimal("0") if rounded.zero?
          whole, fraction = rounded.to_s("F").split(".")
          "#{whole}.#{fraction.ljust(2, '0')}"
        end

        # @param value [BigDecimal]
        # @return [String] the number without a trailing ".0" ("2", "1.5")
        def plain(value)
          value.to_s("F").delete_suffix(".0")
        end

        def canonical(value)
          case value
          when nil then nil
          when Integer then value.to_s
          when BigDecimal, Float then value.finite? ? BigDecimal(value.to_s).to_s("F") : value.to_s
          when String
            text = value.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
            return nil if text.empty?

            GROUPED.match?(text) ? text.delete("   ") : text
          else value.inspect
          end
        end
        private_class_method :canonical
      end
    end
  end
end
