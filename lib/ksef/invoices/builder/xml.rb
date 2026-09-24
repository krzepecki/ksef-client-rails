# frozen_string_literal: true

require "date"
require "forwardable"
require "nokogiri"

module Ksef
  module Invoices
    class Builder
      # Writes a {Builder}'s invoice as FA(3) XML, element by element in the schema's sequence.
      # @api private
      class Xml
        extend Forwardable

        def_delegators :@invoice, *(ATTRIBUTES - %i[annotations]), :totals_by_rate, :gross_total, :correction?,
                       :annotation?, :exempt?, :payment_code, :paid_flag

        # @param invoice [Builder]
        def initialize(invoice)
          @invoice = invoice
        end

        # @param created_at [Time]
        # @return [String]
        def render(created_at)
          Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
            xml.Faktura(xmlns: FormCode::FA3.namespace) do
              header(xml, created_at)
              seller_element(xml)
              buyer_element(xml)
              invoice_body(xml)
              footer_element(xml)
            end
          end.to_xml
        end

        private

        def header(xml, created_at)
          xml.Naglowek do
            xml.KodFormularza("FA", kodSystemowy: FormCode::FA3.system_code, wersjaSchemy: FormCode::FA3.schema_version)
            xml.WariantFormularza "3"
            xml.DataWytworzeniaFa created_at.getutc.strftime("%Y-%m-%dT%H:%M:%SZ")
            xml.SystemInfo system_info
          end
        end

        def seller_element(xml)
          xml.Podmiot1 do
            xml.DaneIdentyfikacyjne do
              xml.NIP Nip.normalize!(seller.nip, name: "seller NIP")
              xml.Nazwa seller.name
            end
            address(xml, seller)
            contact(xml, seller)
          end
        end

        def buyer_element(xml)
          xml.Podmiot2 do
            xml.DaneIdentyfikacyjne do
              buyer_identifier(xml, buyer)
              xml.Nazwa buyer.name
            end
            address(xml, buyer)
            contact(xml, buyer)
            xml.JST "2"
            xml.GV "2"
          end
        end

        # A choice: NIP | KodUE + NrVatUE | KodKraju + NrID | BrakID.
        def buyer_identifier(xml, party)
          case party.identification
          when "nip" then xml.NIP Nip.normalize!(party.nip, name: "buyer NIP")
          when "eu"
            xml.KodUE party.eu_code.to_s.strip.upcase
            xml.NrVatUE party.vat_eu.to_s.strip
          when "other"
            xml.KodKraju party.country
            xml.NrID party.id_number.to_s.strip
          else xml.BrakID "1"
          end
        end

        # Without a country, a party identified by a NIP or by nothing is in Poland.
        def address(xml, party)
          xml.Adres do
            xml.KodKraju blank?(party.country) ? "PL" : party.country
            xml.AdresL1 party.address
          end
        end

        def contact(xml, party)
          email = party.email.to_s.strip
          phone = party.phone.to_s.strip
          return if email.empty? && phone.empty?

          xml.DaneKontaktowe do
            xml.Email email unless email.empty?
            xml.Telefon phone unless phone.empty?
          end
        end

        def invoice_body(xml)
          xml.Fa do
            xml.KodWaluty currency
            xml.P_1 iso(issue_date, "issue_date")
            xml.P_1M place unless blank?(place)
            xml.P_2 number
            xml.P_6 iso(sale_date, "sale_date") if sale_date
            summary(xml)
            annotations_element(xml)
            xml.RodzajFaktury invoice_type
            correction(xml) if correction?
            lines.each_with_index { |line, i| invoice_line(xml, line, i + 1) }
            payment(xml)
          end
        end

        def summary(xml)
          totals = totals_by_rate
          RATES.each do |rate, fields|
            next unless totals[rate]

            xml.public_send(fields[:net], amount(totals[rate][:net]))
            xml.public_send(fields[:vat], amount(totals[rate][:vat])) if fields[:vat]
          end
          xml.P_15 amount(gross_total)
        end

        def annotations_element(xml)
          flag = ->(key) { annotation?(key) ? "1" : "2" }
          xml.Adnotacje do
            %i[cash_method self_billing reverse_charge split_payment].each do |key|
              xml.public_send(ANNOTATIONS[key], flag.call(key))
            end
            exemption(xml)
            xml.NoweSrodkiTransportu { xml.P_22N "1" }
            xml.P_23 flag.call(:triangular)
            xml.PMarzy { xml.P_PMarzyN "1" }
          end
        end

        def exemption(xml)
          xml.Zwolnienie do
            if exempt?
              xml.P_19 "1"
              xml.P_19A exemption_reason
            else
              xml.P_19N "1"
            end
          end
        end

        # `DaneFaKorygowanej` holds a choice: NrKSeF=1 + the KSeF number, or NrKSeFN=1 (issued outside KSeF).
        def correction(xml)
          xml.PrzyczynaKorekty correction_reason unless blank?(correction_reason)
          xml.TypKorekty correction_type unless blank?(correction_type)
          xml.DaneFaKorygowanej do
            xml.DataWystFaKorygowanej iso(corrected_date, "corrected_date")
            xml.NrFaKorygowanej corrected_number
            if blank?(corrected_ksef_number)
              xml.NrKSeFN "1"
            else
              xml.NrKSeF "1"
              xml.NrKSeFFaKorygowanej corrected_ksef_number.strip
            end
          end
        end

        def invoice_line(xml, line, index)
          xml.FaWiersz do
            xml.NrWierszaFa index
            xml.P_7 line.name
            optional(xml, Indeks: line.index, GTIN: line.gtin, PKWiU: line.pkwiu, CN: line.cn, P_8A: line.unit)
            xml.P_8B Number.plain(line.number(:quantity))
            xml.P_9A amount(line.number(:unit_price))
            xml.P_10 amount(line.number(:discount)) if line.discount?
            xml.P_11 amount(line.net)
            xml.P_12 line.rate
            xml.GTU line.gtu unless blank?(line.gtu)
          end
        end

        # Written when any payment field is given. `Zaplacono` + `DataZaplaty` is the first branch of an
        # optional choice, ahead of the due date.
        def payment(xml)
          code = payment_code
          return if code.nil? && !paid_flag && due_date.nil? && blank?(bank_account)

          xml.Platnosc do
            if paid_flag
              xml.Zaplacono "1"
              xml.DataZaplaty iso(paid_date, "paid_date")
            end
            xml.TerminPlatnosci { xml.Termin iso(due_date, "due_date") } if due_date
            xml.FormaPlatnosci code if code
            bank_account_element(xml)
          end
        end

        def bank_account_element(xml)
          return if blank?(bank_account)

          xml.RachunekBankowy do
            xml.NrRB bank_account.delete(" ")
            xml.NazwaBanku bank_name unless blank?(bank_name)
          end
        end

        def footer_element(xml)
          registers = { KRS: krs, REGON: regon, BDO: bdo }.reject { |_, v| blank?(v) }
          return if blank?(footer) && registers.empty?

          xml.Stopka do
            xml.Informacje { xml.StopkaFaktury footer } unless blank?(footer)
            xml.Rejestry { optional(xml, **registers) } if registers.any?
          end
        end

        # Emits each non-blank field in the given (schema) order.
        def optional(xml, **fields)
          fields.each { |tag, value| xml.public_send(tag, value.to_s.strip) unless blank?(value) }
        end

        def blank?(value)
          value.to_s.strip.empty?
        end

        # Only a Date or "YYYY-MM-DD": a Time or a timestamp String is refused, as its calendar day depends
        # on its zone.
        def iso(date, name)
          return nil if date.nil?

          if date.is_a?(String)
            raise Date::Error unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

            return Date.iso8601(date).strftime("%Y-%m-%d")
          end
          unless date.is_a?(Date) && !date.is_a?(DateTime)
            raise ConfigurationError, "#{name} must be a Date or \"YYYY-MM-DD\", not a #{date.class}"
          end

          date.strftime("%Y-%m-%d")
        rescue Date::Error
          raise ConfigurationError, "#{name} is not a valid date (\"YYYY-MM-DD\"): #{date.inspect}"
        end

        def amount(value)
          Number.amount(value)
        end
      end
    end
  end
end
