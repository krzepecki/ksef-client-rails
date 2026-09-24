# frozen_string_literal: true

module Ksef
  module Xades
    # Replaces the ENTIRE XAdES signature with a lambda or object — qualified signature, HSM,
    # EU DSS sidecar. A signer responds to +#sign(xml)+ or +#call(xml)+;
    # {.wrap} normalizes both.
    class ExternalSigner
      # @param callable [#call] object/lambda taking XML and returning signed XML
      # @raise [Ksef::ConfigurationError] when it does not respond to #call
      def initialize(callable)
        unless callable.respond_to?(:call)
          raise ConfigurationError, "ExternalSigner requires an object responding to #call"
        end

        @callable = callable
      end

      # @param xml [String] document to sign
      # @return [String] the signed document
      # @raise [Ksef::CryptoError] when the callable returns anything but a non-empty String
      def sign(xml)
        self.class.signed!(@callable.call(xml))
      end

      # Normalizes a signer into an object responding to +#sign(xml)+.
      # @param signer [#sign, #call]
      # @return [#sign]
      # @raise [Ksef::ConfigurationError] when it responds to neither, or is a key (OpenSSL::PKey#sign signs a
      #   digest, not a document — pass a {Signer})
      def self.wrap(signer)
        if signer.is_a?(OpenSSL::PKey::PKey)
          raise ConfigurationError, "signer is a key — wrap it with its certificate in Ksef::Xades::Signer"
        end
        return signer if signer.respond_to?(:sign) && one_argument?(signer.method(:sign))
        return new(signer) if signer.respond_to?(:call)

        raise ConfigurationError, "signer must respond to #sign(xml) or #call(xml)"
      end

      # @api private
      # @param result [Object] what a signer returned
      # @return [String]
      # @raise [Ksef::CryptoError] unless it is a non-empty String
      def self.signed!(result)
        return result if result.is_a?(String) && !result.strip.empty?

        raise CryptoError, "the signer returned #{result.nil? ? 'nil' : "a #{result.class}"} instead of the signed XML"
      end

      def self.one_argument?(method)
        required = method.parameters.count { |type, _| type == :req }
        required == 1 || (required.zero? && method.parameters.any? { |type, _| %i[opt rest].include?(type) })
      end
      private_class_method :one_argument?
    end
  end
end
