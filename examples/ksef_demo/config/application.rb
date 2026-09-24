# frozen_string_literal: true

require_relative "boot"

# A minimal Rails stack: the controller layer only (no ActiveRecord/assets) — the simplest
# possible demo application for the KSeF gem, boots without a database.
require "rails"
require "action_controller/railtie"

require "ksef"

module KsefDemo
  class Application < Rails::Application
    config.load_defaults 8.1

    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "ksef-demo-secret-key-base-not-for-production-0123456789abcdef"
    config.hosts.clear # a local test app — accept any host
    # KSeF dates follow the Polish calendar (an invoice's P_1, the date filters).
    config.time_zone = "Europe/Warsaw"

    # Kept out of the request log: passwords, KSeF/access/refresh tokens, keys, certificates and invoices.
    config.filter_parameters += %i[passw secret token _key key_file crypt certificate invoice_xml draft]

    # No ActiveRecord — drop the dependent frameworks if they got pulled in.
    config.api_only = false

    # Settings and tokens live in a server-side session: an access + refresh JWT pair overflows the
    # 4 KB cookie store. In-memory, so a server restart logs you out.
    config.cache_store = :memory_store, { size: 64 * 1024 * 1024 }
    config.session_store :cache_store, key: "_ksef_demo_session", expire_after: 12 * 3600
  end
end
