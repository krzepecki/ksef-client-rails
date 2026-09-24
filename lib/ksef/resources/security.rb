# frozen_string_literal: true

module Ksef
  module Resources
    # Security resource — Ministry of Finance public-key certificates.
    # An anonymous endpoint; normally consumed through {Ksef::Crypto::PublicKeys} (with caching),
    # exposed directly here for convenience.
    class Security < Base
      PUBLIC_KEY_CERTIFICATES = "/security/public-key-certificates"

      # GET /security/public-key-certificates — list of Ministry of Finance public-key certificates.
      # @return [Array<Hash>]
      def public_key_certificates
        get(PUBLIC_KEY_CERTIFICATES, bearer: nil)
      end
    end
  end
end
