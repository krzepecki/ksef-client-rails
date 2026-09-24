# frozen_string_literal: true

require "nokogiri"
require "ksef/errors"
require "ksef/models/nip"

module Ksef
  module Xades
    # Builder for the `AuthTokenRequest` XML document (schemat_auth_v2-0.xsd).
    # Element order per the XSD: Challenge, ContextIdentifier, SubjectIdentifierType,
    # optional AuthorizationPolicy → AllowedIps (up to 10 entries of each type).
    class AuthTokenRequest
      NAMESPACE = "http://ksef.mf.gov.pl/auth/token/2.0"

      # Allowed context types → XSD element name.
      CONTEXT_ELEMENTS = {
        nip: "Nip",
        internal_id: "InternalId",
        nip_vat_ue: "NipVatUe",
        peppol_id: "PeppolId"
      }.freeze

      # Allowed ways of identifying the subject → XSD element value.
      SUBJECT_IDENTIFIER_TYPES = {
        certificate_subject: "certificateSubject",
        certificate_fingerprint: "certificateFingerprint"
      }.freeze

      # `allowed_ips` keys → AllowedIps element names, in XSD order.
      ALLOWED_IP_ELEMENTS = { addresses: "Ip4Address", ranges: "Ip4Range", masks: "Ip4Mask" }.freeze
      # Most entries of one AllowedIps type (`maxOccurs`).
      MAX_ALLOWED_IPS = 10

      # @return [String, nil] value from POST /auth/challenge — may be set after the other inputs were checked
      attr_accessor :challenge

      # @param challenge [String, nil] value from POST /auth/challenge (36 characters); required by {#to_xml}
      # @param context [Hash] exactly one of: {nip:}, {internal_id:}, {nip_vat_ue:}, {peppol_id:}; a NIP
      #   is normalized ({Ksef::Nip.normalize!})
      # @param subject_identifier_type [Symbol] :certificate_subject or :certificate_fingerprint
      # @param allowed_ips [Hash, nil] optional: {addresses:[], ranges:[], masks:[]} (symbol or string
      #   keys); no entries means no AuthorizationPolicy
      # @raise [Ksef::ConfigurationError] for an unknown or malformed context, an invalid NIP, subject type,
      #   allowed_ips key or more than {MAX_ALLOWED_IPS} entries of one type
      def initialize(context:, challenge: nil, subject_identifier_type: :certificate_subject, allowed_ips: nil)
        @challenge = challenge
        @context = normalize_context(context)
        @subject_identifier_type = fetch_subject_type(subject_identifier_type)
        @allowed_ips = normalize_allowed_ips(allowed_ips)
      end

      # @return [String] XML document (unsigned; to be passed to {Signer})
      # @raise [Ksef::ConfigurationError] without a challenge
      def to_xml
        build_document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      # @return [Nokogiri::XML::Document]
      # @raise [Ksef::ConfigurationError] without a challenge
      def to_document
        build_document
      end

      private

      def build_document
        raise ConfigurationError, "AuthTokenRequest needs the challenge" if @challenge.to_s.empty?

        Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
          xml.AuthTokenRequest(xmlns: NAMESPACE) do
            xml.Challenge(@challenge)
            xml.ContextIdentifier do
              xml.send(@context[:element], @context[:value])
            end
            xml.SubjectIdentifierType(@subject_identifier_type)
            build_authorization_policy(xml) unless @allowed_ips.empty?
          end
        end.doc
      end

      def build_authorization_policy(xml)
        xml.AuthorizationPolicy do
          xml.AllowedIps do
            @allowed_ips.each { |element, ip| xml.send(element, ip) }
          end
        end
      end

      # @return [Array<Array(String, String)>] [element, value] pairs in XSD order
      def normalize_allowed_ips(allowed_ips)
        unless allowed_ips.nil? || allowed_ips.is_a?(Hash)
          raise ConfigurationError, "allowed_ips must be a Hash ({addresses:, ranges:, masks:})"
        end

        ips = (allowed_ips || {}).transform_keys(&:to_sym)
        unknown = ips.keys - ALLOWED_IP_ELEMENTS.keys
        unless unknown.empty?
          raise ConfigurationError,
                "allowed_ips accepts only #{ALLOWED_IP_ELEMENTS.keys.join(', ')} (got #{unknown.join(', ')})"
        end

        ALLOWED_IP_ELEMENTS.flat_map do |key, element|
          list = Array(ips[key])
          raise ConfigurationError, "allowed_ips #{key}: at most #{MAX_ALLOWED_IPS} entries" if
            list.size > MAX_ALLOWED_IPS

          list.map { |ip| [element, ip.to_s] }
        end
      end

      def normalize_context(context)
        unless context.is_a?(Hash)
          raise ConfigurationError, "context must be a Hash with exactly one of: #{CONTEXT_ELEMENTS.keys.join(', ')}"
        end

        pairs = context.transform_keys(&:to_sym)
        key, value = pairs.first
        unless pairs.size == 1 && CONTEXT_ELEMENTS.key?(key)
          raise ConfigurationError,
                "context must contain exactly one of: #{CONTEXT_ELEMENTS.keys.join(', ')}"
        end

        value = key == :nip ? Nip.normalize!(value, name: "context nip") : value.to_s
        { element: CONTEXT_ELEMENTS.fetch(key), value: value }
      end

      def fetch_subject_type(type)
        SUBJECT_IDENTIFIER_TYPES.fetch(type.respond_to?(:to_sym) ? type.to_sym : nil) do
          raise ConfigurationError,
                "subject_identifier_type must be one of: #{SUBJECT_IDENTIFIER_TYPES.keys.join(', ')}"
        end
      end
    end
  end
end
