# frozen_string_literal: true

require "nokogiri"
require "openssl"
require "base64"
require "digest"
require "time"

module Ksef
  module Xades
    # XAdES-BASELINE-B (enveloped) signature over AuthTokenRequest, shaped like C# `SignatureService`
    # but with the algorithms named explicitly (see the constants); for ECDSA the SignatureValue is
    # R‖S (IEEE P1363), not DER. Replaceable by any callable — see {ExternalSigner}.
    class Signer
      DS_NS = "http://www.w3.org/2000/09/xmldsig#"
      XADES_NS = "http://uri.etsi.org/01903/v1.3.2#"
      EXC_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
      ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
      # SHA-256 digests come from XML Encryption, not the xmldsig namespace (which only defines
      # SHA-1) — KSeF rejects any other identifier with code 9105 "Nieprawidłowy podpis".
      SHA256_DIGEST = "http://www.w3.org/2001/04/xmlenc#sha256"
      RSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
      ECDSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"
      SIGNED_PROPERTIES_TYPE = "http://uri.etsi.org/01903#SignedProperties"

      C14N_MODE = Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0

      # Attribute names RFC 2253 allows in short form; everything else must go out as `OID.x.y.z`,
      # because that is what X500 parsers on the KSeF side accept (OpenSSL's own long names, e.g.
      # `organizationIdentifier` for 2.5.4.97, are not recognized keywords). Matched case-insensitively:
      # OpenSSL names streetAddress `street`.
      RFC2253_SHORT_NAMES = %w[CN L ST O OU C STREET DC UID].freeze
      # Smallest keys KSeF accepts (podpis-xades.md): RSA modulus and EC field size, in bits.
      MIN_RSA_BITS = 2048
      MIN_EC_BITS = 256
      # An xsd:ID value (NCName), as the signature's Id attributes must be.
      NCNAME = /\A[A-Za-z_][\w.-]*\z/
      # Issuer DN string types → the encoding of their bytes (UTF8String, PrintableString, IA5String, … are UTF-8).
      STRING_ENCODINGS = { OpenSSL::ASN1::BMPString => Encoding::UTF_16BE,
                           OpenSSL::ASN1::UniversalString => Encoding::UTF_32BE,
                           OpenSSL::ASN1::T61String => Encoding::ISO_8859_1 }.freeze

      # Builds a signer that signs with a local certificate + private key.
      #
      # @param cert [OpenSSL::X509::Certificate] signing certificate
      # @param key [OpenSSL::PKey::RSA, OpenSSL::PKey::EC] private key
      # @param signature_id [String] Id of the ds:Signature element
      # @param signed_properties_id [String] Id of the xades:SignedProperties element
      # @param clock [#call] signing time source (for tests)
      # @raise [Ksef::CryptoError] for a certificate that is not an OpenSSL::X509::Certificate, a key KSeF
      #   refuses or one that does not match it, or an Id that is not an NCName
      def initialize(cert:, key:, signature_id: "Signature", signed_properties_id: "SignedProperties",
                     clock: -> { Time.now.utc })
        @cert = cert
        @key = key
        @signature_id = signature_id
        @signed_properties_id = signed_properties_id
        @clock = clock
        validate_ids!
        validate_key!
      end

      # Signs the XML document and returns the signed XML as a string.
      #
      # @param xml [String, Nokogiri::XML::Document] AuthTokenRequest document (unsigned)
      # @return [String] document with the ds:Signature element attached
      def sign(xml)
        doc = parse(xml.is_a?(Nokogiri::XML::Document) ? xml.to_xml : xml)
        root = doc.root || raise(CryptoError, "The XML document has no root element")

        # 1) The URI="" digest — the whole document without comments (top-level processing instructions
        #    included), computed BEFORE the signature is attached: the enveloped transform removes it.
        root_digest = sha256_base64(canonicalize(doc))

        # 2) Build and attach the signature skeleton (SignedProperties DigestValue and SignatureValue empty).
        signature = build_signature_skeleton(doc, root_digest)
        root.add_child(signature)

        # 3) SignedProperties digest — canonicalized in the final namespace context.
        signed_props = at(signature, ".//xades:SignedProperties")
        set_text(signature, ".//ds:Reference[@URI='##{@signed_properties_id}']/ds:DigestValue",
                 sha256_base64(canonicalize(signed_props)))

        # 4) Sign SignedInfo -> SignatureValue.
        signed_info = at(signature, "./ds:SignedInfo")
        signature_value = sign_bytes(canonicalize(signed_info))
        set_text(signature, "./ds:SignatureValue", Base64.strict_encode64(signature_value))

        serialize(doc)
      end

      private

      def validate_ids!
        [@signature_id, @signed_properties_id].each do |id|
          raise CryptoError, "Signature Id #{id.inspect} is not an NCName" unless id.to_s.match?(NCNAME)
        end
      end

      def validate_key!
        raise CryptoError, "cert must be an OpenSSL::X509::Certificate, not #{@cert.class}" unless
          @cert.is_a?(OpenSSL::X509::Certificate)
        unless @key.is_a?(OpenSSL::PKey::RSA) || @key.is_a?(OpenSSL::PKey::EC)
          raise CryptoError, "Unsupported key type: #{@key.class} (expected RSA or EC)"
        end
        raise CryptoError, "The key has no private part — signing needs the private key" unless @key.private?

        validate_key_size!

        # A mismatched pair produces a well-formed signature that verifies against nothing — KSeF
        # answers 9105 ("Nieprawidłowy podpis"), which says nothing about the cause.
        return if @cert.check_private_key(@key)

        raise CryptoError, "The private key does not match the certificate's public key"
      end

      def validate_key_size!
        bits = rsa? ? @key.n.num_bits : @key.group.degree
        minimum = rsa? ? MIN_RSA_BITS : MIN_EC_BITS
        return if bits >= minimum

        raise CryptoError, "The #{rsa? ? 'RSA' : 'EC'} key has #{bits} bits; KSeF requires at least #{minimum}"
      end

      # Strict: a malformed document is refused rather than repaired and signed; a DOCTYPE (entities)
      # has no place in an AuthTokenRequest.
      def parse(xml)
        doc = Nokogiri::XML(xml) { |config| config.strict.nonet }
        raise CryptoError, "The XML document must not declare a DOCTYPE" if doc.internal_subset

        doc
      rescue Nokogiri::XML::SyntaxError => e
        raise CryptoError, "The XML document is not well-formed: #{e.message}"
      end

      # Builds the ds:Signature element (as a standalone fragment without stray whitespace, so
      # that canonicalizing sub-elements is deterministic). Returns the signature node; the caller
      # attaches it via add_child (Nokogiri reparents across documents).
      def build_signature_skeleton(_doc, root_digest)
        sig_xml = signature_template(root_digest)
        Nokogiri::XML(sig_xml) { |config| config.strict.noblanks }.root
      rescue Nokogiri::XML::SyntaxError => e
        raise CryptoError, "The signature could not be built: #{e.message}"
      end

      def signature_template(root_digest)
        <<~XML.gsub(/>\s+</, "><").strip
          <ds:Signature xmlns:ds="#{DS_NS}" Id="#{@signature_id}">
            <ds:SignedInfo>
              <ds:CanonicalizationMethod Algorithm="#{EXC_C14N}"/>
              <ds:SignatureMethod Algorithm="#{signature_method}"/>
              <ds:Reference URI="">
                <ds:Transforms>
                  <ds:Transform Algorithm="#{ENVELOPED}"/>
                  <ds:Transform Algorithm="#{EXC_C14N}"/>
                </ds:Transforms>
                <ds:DigestMethod Algorithm="#{SHA256_DIGEST}"/>
                <ds:DigestValue>#{root_digest}</ds:DigestValue>
              </ds:Reference>
              <ds:Reference Type="#{SIGNED_PROPERTIES_TYPE}" URI="##{@signed_properties_id}">
                <ds:Transforms>
                  <ds:Transform Algorithm="#{EXC_C14N}"/>
                </ds:Transforms>
                <ds:DigestMethod Algorithm="#{SHA256_DIGEST}"/>
                <ds:DigestValue></ds:DigestValue>
              </ds:Reference>
            </ds:SignedInfo>
            <ds:SignatureValue></ds:SignatureValue>
            <ds:KeyInfo>
              <ds:X509Data>
                <ds:X509Certificate>#{cert_base64}</ds:X509Certificate>
              </ds:X509Data>
            </ds:KeyInfo>
            #{qualifying_properties}
          </ds:Signature>
        XML
      end

      def qualifying_properties
        <<~XML
          <ds:Object>
            <xades:QualifyingProperties xmlns:xades="#{XADES_NS}" xmlns="#{DS_NS}" Target="##{@signature_id}">
              <xades:SignedProperties Id="#{@signed_properties_id}">
                <xades:SignedSignatureProperties>
                  <xades:SigningTime>#{signing_time}</xades:SigningTime>
                  <xades:SigningCertificate>
                    <xades:Cert>
                      <xades:CertDigest>
                        <DigestMethod Algorithm="#{SHA256_DIGEST}"/>
                        <DigestValue>#{cert_digest}</DigestValue>
                      </xades:CertDigest>
                      <xades:IssuerSerial>
                        <X509IssuerName>#{xml_escape(issuer_name)}</X509IssuerName>
                        <X509SerialNumber>#{serial_number}</X509SerialNumber>
                      </xades:IssuerSerial>
                    </xades:Cert>
                  </xades:SigningCertificate>
                </xades:SignedSignatureProperties>
              </xades:SignedProperties>
            </xades:QualifyingProperties>
          </ds:Object>
        XML
      end

      # --- cryptographic signature --------------------------------------------------------

      def sign_bytes(data)
        signature = @key.sign(OpenSSL::Digest.new("SHA256"), data)
        rsa? ? signature : der_to_p1363(signature)
      end

      # Converts an ECDSA signature from DER (SEQUENCE{r,s}) to IEEE P1363 (fixed-length R‖S).
      def der_to_p1363(der)
        asn1 = OpenSSL::ASN1.decode(der)
        byte_len = (@key.group.degree + 7) / 8
        r = asn1.value[0].value.to_s(2).rjust(byte_len, "\x00")
        s = asn1.value[1].value.to_s(2).rjust(byte_len, "\x00")
        r + s
      end

      def signature_method
        rsa? ? RSA_SHA256 : ECDSA_SHA256
      end

      def rsa?
        @key.is_a?(OpenSSL::PKey::RSA)
      end

      # --- certificate fields -------------------------------------------------------------

      def cert_base64
        Base64.strict_encode64(@cert.to_der)
      end

      def cert_digest
        Base64.strict_encode64(Digest::SHA256.digest(@cert.to_der))
      end

      # RFC 2253 issuer DN (most-specific RDN first, the values of a multi-valued RDN joined by "+"),
      # shaped like the reference C# client: short names where the RFC defines them, `OID.x.y.z` otherwise.
      def issuer_name
        OpenSSL::ASN1.decode(@cert.issuer.to_der).value.reverse.map do |rdn|
          rdn.value.map { |ava| "#{dn_key(ava.value[0])}=#{dn_value(ava.value[1])}" }.join("+")
        end.join(",")
      end

      def dn_key(oid)
        short = oid.sn.to_s.upcase
        RFC2253_SHORT_NAMES.include?(short) ? short : "OID.#{oid.oid}"
      end

      # The value decoded by its string type and escaped per RFC 4514; a value of any other type goes out
      # as "#" and the hex of its DER.
      def dn_value(value)
        return "##{value.to_der.unpack1('H*').upcase}" unless value.value.is_a?(String)

        text = value.value.dup.force_encoding(STRING_ENCODINGS.fetch(value.class, Encoding::UTF_8))
        text = text.encode(Encoding::UTF_8)
        raise EncodingError unless text.valid_encoding?

        escape_dn(text)
      rescue EncodingError
        raise CryptoError, "The certificate issuer holds a value that is not valid text"
      end

      def escape_dn(text)
        escaped = text.gsub(/([,+"\\<>;])/) { "\\#{Regexp.last_match(1)}" }
                      .gsub(/[\x00-\x1F\x7F]/) { |char| format("\\%02X", char.ord) }
        escaped = "\\#{escaped}" if escaped.start_with?("#", " ")
        escaped.end_with?(" ") ? "#{escaped[0..-2]}\\ " : escaped
      end

      def serial_number
        @cert.serial.to_s
      end

      def signing_time
        @clock.call.utc.iso8601(3)
      end

      # --- canonicalization / XML ---------------------------------------------------------

      def canonicalize(node)
        node.canonicalize(C14N_MODE)
      rescue RuntimeError => e
        raise CryptoError, "XML canonicalization failed: #{e.message}"
      end

      def sha256_base64(bytes)
        Base64.strict_encode64(Digest::SHA256.digest(bytes))
      end

      def at(node, xpath)
        node.at_xpath(xpath, "ds" => DS_NS, "xades" => XADES_NS) ||
          raise(CryptoError, "Signature node not found: #{xpath}")
      end

      def set_text(node, xpath, text)
        at(node, xpath).content = text
      end

      def serialize(doc)
        doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      def xml_escape(text)
        text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
            .gsub('"', "&quot;").gsub("'", "&apos;")
      end
    end
  end
end
