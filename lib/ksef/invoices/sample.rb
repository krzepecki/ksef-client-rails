# frozen_string_literal: true

require "date"

module Ksef
  module Invoices
    # Three FA(3) invoices built with {Builder}, each accepted on KSeF TEST: a starting point to copy or
    # to adapt. `examples/fa3_{minimal,typical,full}.xml` are their XML.
    module Sample
      # Placeholder parties; the buyer's NIP is valid but belongs to no one in particular.
      SELLER = { name: "Seller Ltd.", address: "1 Test Street, 00-001 Warsaw", country: "PL" }.freeze
      BUYER = { nip: "1111111111", name: "Buyer Inc.", address: "2 Example Street, 00-002 Warsaw",
                country: "PL" }.freeze

      module_function

      # One 23% line — the fields every invoice needs.
      # @param seller_nip [String] the session's context NIP
      # @param invoice_number [String] `P_2`, unique per seller
      # @param issue_date [Date] `P_1`, the calendar day in Poland: KSeF refuses a later day and marks an
      #   earlier one as issued offline
      # @return [Builder]
      def minimal(seller_nip:, invoice_number:, issue_date: PolishTime.today)
        Builder.new(
          number: invoice_number, issue_date: issue_date, currency: "PLN",
          seller: SELLER.merge(nip: seller_nip), buyer: BUYER,
          lines: [{ name: "Demo service", unit: "szt.", quantity: "1", unit_price: "100.00", rate: "23" }]
        )
      end

      # {minimal} plus the sale date, the place of issue and a bank transfer due in 14 days.
      # @param (see minimal)
      # @return [Builder]
      def typical(seller_nip:, invoice_number:, issue_date: PolishTime.today)
        minimal(seller_nip: seller_nip, invoice_number: invoice_number, issue_date: issue_date).tap do |invoice|
          invoice.sale_date = issue_date
          invoice.place = "Warsaw"
          invoice.payment_method = :transfer
          invoice.due_date = issue_date + 14
          invoice.bank_account = "17100000000000000000000001"
        end
      end

      # A VAT invoice with most fields {Builder} supports: contact data, five rates (23, 8, 5, 0 domestic,
      # exempt), line details and a discount, a transfer with the bank's name, the footer and registers.
      # Not shown: a payment already made, a buyer identified other than by NIP, a correction, annotations
      # and the other five rates.
      # @param (see minimal)
      # @return [Builder]
      def full(seller_nip:, invoice_number:, issue_date: PolishTime.today)
        typical(seller_nip: seller_nip, invoice_number: invoice_number, issue_date: issue_date).tap do |invoice|
          invoice.seller = SELLER.merge(nip: seller_nip, email: "invoices@seller.example", phone: "+48 22 000 00 00")
          invoice.buyer = BUYER.merge(email: "accounts@buyer.example")
          invoice.lines = full_lines
          invoice.exemption_reason = "Art. 43 ust. 1 pkt 37 ustawy o VAT"
          invoice.bank_name = "Example Bank"
          invoice.footer = "Thank you for your business."
          invoice.krs = "0000123456"
          invoice.regon = "123456785"
          invoice.bdo = "000012345"
        end
      end

      def full_lines
        [
          { name: "Software licence", unit: "szt.", quantity: "2", unit_price: "1000.00", rate: "23",
            index: "LIC-01", gtin: "5901234123457", pkwiu: "58.29.50.0", cn: "8523", gtu: "GTU_12",
            discount: "100.00" },
          { name: "Printed manual", unit: "szt.", quantity: "1", unit_price: "50.00", rate: "5" },
          { name: "Catering", unit: "szt.", quantity: "3", unit_price: "40.00", rate: "8" },
          { name: "Zero-rated supply", unit: "szt.", quantity: "1", unit_price: "20.00", rate: "0 KR" },
          { name: "Insurance", unit: "szt.", quantity: "1", unit_price: "30.00", rate: "zw" }
        ]
      end
      private_class_method :full_lines
    end
  end
end
