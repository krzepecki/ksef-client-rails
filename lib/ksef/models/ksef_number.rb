# frozen_string_literal: true

module Ksef
  # KSeF number value object, e.g. `5555555555-20250826-0100001AF629-72`.
  #
  # The trailing 2 HEX characters are CRC-8 (poly 0x07, init 0x00) over everything before the
  # last "-", hyphens included. The pattern also accepts the 36-character form (with a "-" inside the
  # 12-character hex part).
  class KsefNumber
    CRC8_POLYNOMIAL = 0x07
    CRC8_INIT = 0x00
    # `KsefNumber` in the KSeF contract: seller NIP, date (YYYYMMDD), uppercase hex, CRC.
    PATTERN = /\A[1-9](\d[1-9]|[1-9]\d)\d{7}-(20[2-9]\d|2[1-9]\d{2}|[3-9]\d{3})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])-
               [0-9A-F]{6}-?[0-9A-F]{6}-[0-9A-F]{2}\z/x

    # @return [String] raw number value
    attr_reader :value

    # @param value [String]
    def initialize(value)
      @value = value.to_s
    end

    # @return [Boolean] whether the number matches the contract pattern and its CRC-8 checksum
    def valid?
      return false unless @value.match?(PATTERN)

      data, _sep, checksum = @value.rpartition("-")
      checksum == format("%02X", self.class.crc8(data))
    end

    # Validates and returns the object, or raises.
    # @return [self]
    # @raise [Ksef::ConfigurationError] when the number is invalid
    def validate!
      raise ConfigurationError, "Invalid KSeF number: #{@value.inspect}" unless valid?

      self
    end

    # @return [String] seller tax identification number (the first 10 characters)
    def seller_nip
      @value[0, 10]
    end

    def to_s
      @value
    end

    # Equal to another KsefNumber with the same value (not to a String, so that equality stays symmetric).
    def ==(other)
      other.is_a?(KsefNumber) && value == other.value
    end
    alias eql? ==

    def hash
      value.hash
    end

    # Computes CRC-8 (poly 0x07, init 0x00, no reflection or xorout) over ASCII bytes.
    # @param string [String]
    # @return [Integer] value 0–255
    def self.crc8(string)
      crc = CRC8_INIT
      string.each_byte do |byte|
        crc ^= byte
        8.times do
          crc = crc.anybits?(0x80) ? ((crc << 1) ^ CRC8_POLYNOMIAL) & 0xFF : (crc << 1) & 0xFF
        end
      end
      crc
    end
  end
end
