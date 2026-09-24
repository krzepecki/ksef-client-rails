# frozen_string_literal: true

module Ksef
  module Qr
    # Renders a QR code from a verification link; the SVG carries the label KSeF prescribes below
    # the code. Requires the optional `rqrcode` gem, loaded lazily.
    class Code
      # Quiet zone (modules of white border) required by ISO/IEC 18004.
      QUIET_ZONE = 4
      # Height of the label band below the quiet zone, in modules.
      LABEL_BAND = 6
      # Largest label font size, in modules; a long label (a KSeF number) shrinks to the code's width.
      LABEL_MAX_FONT = 3
      # Advance of one monospace glyph, in em — what sizes the label to fit.
      MONOSPACE_ADVANCE = 0.6
      # Colours the SVG accepts: hex digits without "#" (String) or a colour name (Symbol).
      HEX_COLOR = /\A(?:\h{3}|\h{4}|\h{6}|\h{8})\z/
      NAMED_COLOR = /\A[a-z]+\z/i

      # @return [String] the encoded link
      attr_reader :data
      # @return [String, nil] label below the code — the KSeF number or "OFFLINE" (CODE I),
      #   "CERTYFIKAT" (CODE II); KSeF prescribes these Polish labels
      attr_reader :label

      # @param data [String] verification link to encode
      # @param label [String, nil] label printed below the code
      def initialize(data, label: nil)
        @data = data
        @label = label
      end

      # @return [RQRCode::QRCode]
      # @raise [Ksef::ConfigurationError] when rqrcode is not installed
      def qrcode
        @qrcode ||= begin
          Ksef.require_optional("rqrcode", "QR rendering")
          RQRCode::QRCode.new(@data, level: :m)
        end
      end

      # Scalable by CSS (`viewBox`, no fixed width/height — a fixed-size SVG squeezed by CSS gets
      # cropped, not scaled, and no phone can read it), with the 4-module white quiet zone the QR
      # standard requires and the {#label} centred below it.
      # @param module_size [Integer] user units per module (the coordinate scale; CSS sets the size)
      # @param color [String, Symbol] colour of the modules and the label: hex without "#", or a name
      # @return [String] QR code as SVG
      # @raise [Ksef::ConfigurationError] for any other colour (it is written into SVG attributes)
      def as_svg(module_size: 11, color: "000")
        validate_color!(color)
        size = (qrcode.modules.length + (2 * QUIET_ZONE)) * module_size
        height = label? ? size + (LABEL_BAND * module_size) : size
        modules = qrcode.as_svg(standalone: false, use_path: true, module_size: module_size,
                                offset: QUIET_ZONE * module_size, color: color)
        root = %(xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 #{size} #{height}")
        [
          %(<svg #{root} shape-rendering="crispEdges">),
          %(<rect width="#{size}" height="#{height}" fill="#fff"/>),
          modules,
          label_svg(size, module_size, color),
          "</svg>"
        ].join
      end

      # @param options [Hash] passed to rqrcode (e.g. size, border_modules)
      # @return [String] the code alone (no label) as binary PNG data
      def as_png(**)
        qrcode.as_png(size: 300, **).to_s
      end

      # @return [String] the code alone (no label) as an ANSI terminal preview
      def as_ascii
        qrcode.as_ansi
      end

      private

      def label?
        !label.to_s.empty?
      end

      def validate_color!(color)
        valid = color.is_a?(Symbol) ? color.to_s.match?(NAMED_COLOR) : color.is_a?(String) && color.match?(HEX_COLOR)
        return if valid

        raise ConfigurationError, "color must be hex digits without \"#\" or a Symbol colour name, got #{color.inspect}"
      end

      def label_svg(size, module_size, color)
        return "" unless label?

        text = label.to_s
        font = [LABEL_MAX_FONT * module_size, (size - (2 * module_size)) / (text.length * MONOSPACE_ADVANCE)].min
        baseline = size + (((LABEL_BAND * module_size) + (0.7 * font)) / 2)
        fill = color.is_a?(Symbol) ? color : "##{color}"
        attributes = [
          %(x="#{size / 2.0}"), %(y="#{baseline.round(2)}"), 'text-anchor="middle"', 'font-family="monospace"',
          %(font-size="#{font.round(2)}"), 'font-weight="bold"', %(fill="#{fill}")
        ].join(" ")
        "<text #{attributes}>#{text.encode(xml: :text)}</text>"
      end
    end
  end
end
