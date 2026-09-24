# frozen_string_literal: true

require "ksef/version"

# Main module of the KSeF gem: global configuration plus loading of every layer.
module Ksef
  class << self
    # Configures the global gem settings.
    # @yieldparam config [Ksef::Configuration]
    # @return [Ksef::Configuration]
    def configure
      yield(config) if block_given?
      config
    end

    # @return [Ksef::Configuration] global configuration (lazily initialized)
    def config
      @config ||= Configuration.new
    end

    # Overrides the global configuration (e.g. in tests).
    # @param configuration [Ksef::Configuration]
    attr_writer :config

    # Resets the global configuration back to the default.
    # @return [void]
    def reset_config!
      @config = nil
    end

    # Loads an optional dependency (rqrcode, minitar), naming the feature that needs it when missing.
    # @api private
    # @param gem_name [String]
    # @param feature [String] e.g. "QR rendering"
    # @return [void]
    # @raise [Ksef::ConfigurationError] when the gem is not installed
    def require_optional(gem_name, feature)
      require gem_name
    rescue LoadError
      raise ConfigurationError, "#{feature} requires the '#{gem_name}' gem — add it to your Gemfile"
    end
  end
end

# Foundation (no dependencies on the rest)
require "ksef/errors"
require "ksef/environments"
require "ksef/configuration"
require "ksef/polling"
require "ksef/polish_time"

# HTTP layer
require "ksef/http/error_parser"
require "ksef/http/connection"
require "ksef/http/pagination"

# Cryptography
require "ksef/crypto/public_keys"
require "ksef/crypto/cryptography_service"
require "ksef/crypto/csr"

# XAdES
require "ksef/xades/auth_token_request"
require "ksef/xades/signer"
require "ksef/xades/external_signer"

# Authentication
require "ksef/auth/ksef_token_encryptor"
require "ksef/auth/coordinator"

# Models (value objects and DTOs)
require "ksef/models/form_code"
require "ksef/models/nip"
require "ksef/models/ksef_number"

# Domain resources (1:1 with endpoints)
require "ksef/resources/base"
require "ksef/resources/auth"
require "ksef/resources/security"
require "ksef/resources/sessions"
require "ksef/resources/online_sessions"
require "ksef/resources/batch_sessions"
require "ksef/resources/invoices"
require "ksef/resources/exports"
require "ksef/resources/collective_identifiers"
require "ksef/resources/certificates"
require "ksef/resources/tokens"
require "ksef/resources/permissions"
require "ksef/resources/limits"
require "ksef/resources/peppol"
require "ksef/resources/test_data"

# High-level flows
require "ksef/sessions/online"
require "ksef/invoices/export"
require "ksef/invoices/schema_outline"
require "ksef/invoices/builder"
require "ksef/invoices/sample"
require "ksef/invoices/validator"
require "ksef/sync/incremental"
require "ksef/batch/package_builder"
require "ksef/batch/splitter"
require "ksef/batch/uploader"

# QR
require "ksef/qr/verification_link"
require "ksef/qr/code"

# DX
require "ksef/token_manager"

# Facade
require "ksef/client"

# Rails integration — loaded conditionally when Rails is defined (Faraday/Stripe pattern).
require "ksef/railtie" if defined?(Rails::Railtie)
