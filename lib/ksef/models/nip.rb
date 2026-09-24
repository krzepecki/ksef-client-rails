# frozen_string_literal: true

module Ksef
  # Polish tax identification number (NIP): the contract's pattern (no leading zero, digits 2–3 not
  # both zero) plus the mod-11 checksum — weights [6,5,7,2,3,4,5,6,7], a remainder of 10 is invalid.
  class Nip
    WEIGHTS = [6, 5, 7, 2, 3, 4, 5, 6, 7].freeze
    # `Nip` in the KSeF contract.
    PATTERN = /\A[1-9]((\d[1-9])|([1-9]\d))\d{7}\z/

    # @return [String] digits only (separators and the "PL" prefix stripped)
    attr_reader :value

    # Normalizes a NIP given to the gem, refusing an invalid one before it reaches KSeF or a QR link.
    # @param value [String, Nip] tax id; spaces (no-break ones too), dashes and a "PL" prefix are stripped
    # @param name [String] argument name for the error message
    # @return [String] the 10 digits
    # @raise [Ksef::ConfigurationError] when the number is invalid
    def self.normalize!(value, name: "NIP")
      nip = value.is_a?(Nip) ? value : new(value)
      raise ConfigurationError, "#{name} is not a valid NIP: #{value.to_s.dump}" unless nip.valid?

      nip.value
    end

    # @param value [String] tax id; spaces (no-break ones too), dashes and a "PL" prefix are stripped
    def initialize(value)
      @value = value.to_s.gsub(/[[:space:]\p{Pd}]/, "").sub(/\APL/i, "")
    end

    # @return [Boolean] whether it matches the contract pattern and has a valid check digit
    def valid?
      return false unless @value.match?(PATTERN)

      digits = @value.chars.map(&:to_i)
      checksum = WEIGHTS.each_with_index.sum { |w, i| w * digits[i] } % 11
      checksum != 10 && checksum == digits[9]
    end

    # @return [self]
    # @raise [Ksef::ConfigurationError] when the number is invalid
    def validate!
      raise ConfigurationError, "Invalid tax identification number: #{@value.inspect}" unless valid?

      self
    end

    def to_s
      @value
    end

    # Equal to another Nip with the same digits (not to a String, so that equality stays symmetric).
    def ==(other)
      other.is_a?(Nip) && value == other.value
    end
    alias eql? ==

    def hash
      value.hash
    end
  end
end
