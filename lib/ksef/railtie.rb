# frozen_string_literal: true

require "rails/railtie"

module Ksef
  # Rails integration, loaded only when Rails is defined: configures the gem from `config.ksef.*` (any
  # {Ksef::Configuration::OPTIONS} key) and logs to `Rails.logger` by default, before the app's
  # initializers run, so `config/initializers/ksef.rb` always has the last word.
  class Railtie < ::Rails::Railtie
    config.ksef = ActiveSupport::OrderedOptions.new if defined?(ActiveSupport::OrderedOptions)

    initializer "ksef.configure", before: :load_config_initializers do |app|
      options = app.config.respond_to?(:ksef) ? app.config.ksef.to_h : {}
      Ksef.configure do |ksef|
        ksef.logger = ::Rails.logger # `config.ksef.logger` overrides it (nil turns logging off)
        ksef.apply(options)
      end
    end
  end
end
