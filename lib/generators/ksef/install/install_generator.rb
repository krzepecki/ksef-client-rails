# frozen_string_literal: true

require "rails/generators/base"

module Ksef
  module Generators
    # Install generator: `rails g ksef:install`.
    # Creates `config/initializers/ksef.rb` with pointers to Rails credentials.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates the KSeF initializer at config/initializers/ksef.rb"

      # Copies the initializer template into the application.
      def copy_initializer
        template "ksef.rb", "config/initializers/ksef.rb"
      end
    end
  end
end
