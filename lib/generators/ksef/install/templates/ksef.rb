# frozen_string_literal: true

# KSeF client configuration (the `ksef-client-rails` gem) — https://github.com/CIRFMF/ksef-api
# Keep the KSeF token and certificates in Rails credentials, never in the repository.
# This file runs after `config.ksef.*` from config/application.rb (railtie), so whatever it sets wins.

Ksef.configure do |config|
  # Environment: :test | :demo | :prod — set it explicitly for every deployment. Never derive it from
  # Rails.env: staging usually runs with RAILS_ENV=production, and every invoice sent to :prod is
  # legally binding. Without KSEF_ENV (or with it empty) the environment stays as configured (default :test).
  config.environment = ENV["KSEF_ENV"].presence || config.environment

  # Timeouts in seconds (defaults: 60 and 15):
  # config.timeout = 60
  # config.open_timeout = 15

  # The railtie logs to Rails.logger; nil turns logging off:
  # config.logger = nil

  # A 429 asking to wait longer than this (seconds) raises Ksef::RateLimited instead of sleeping:
  # config.max_retry_after = 60

  # API feature flags sent as X-KSeF-Feature (e.g. "subject-identifier-validation" on TEST/DEMO):
  # config.ksef_features = %w[]
end
