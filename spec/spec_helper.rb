# frozen_string_literal: true

require "ksef"
require "webmock/rspec"

WebMock.disable_net_connect!

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  # Reset the global configuration between tests (statelessness).
  config.after { Ksef.reset_config! }
end
