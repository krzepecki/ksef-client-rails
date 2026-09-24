# frozen_string_literal: true

require_relative "lib/ksef/version"

Gem::Specification.new do |spec|
  spec.name        = "ksef-client-rails"
  spec.version     = Ksef::VERSION
  spec.authors     = ["krzepecki"]
  spec.summary     = "Ruby/Rails client for the Polish KSeF (National e-Invoice System) API 2.0"
  spec.description = <<~DESC
    Pure-Ruby client for KSeF API 2.0 (Krajowy System e-Faktur). Provides low-level 1:1
    endpoint access plus high-level coordinators for authentication (XAdES), interactive
    and batch invoice sessions, invoice download/export, incremental sync, KSeF certificates,
    tokens, permissions and offline QR codes. Rails integration is loaded conditionally.
  DESC
  spec.homepage = "https://github.com/krzepecki/ksef-client-rails"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The form XSD schemas (FA(2), FA(3), FA_RR(1) + base types) ship with the gem so that
  # Ksef::Invoices::Validator works offline for users — see schemas/README.md — and so do the three
  # sample invoices of Ksef::Invoices::Sample. Only git-tracked files are packaged, so a stray file in
  # the working tree (e.g. a real invoice dropped into examples/) never reaches the .gem.
  packaged = Dir[
    "lib/**/*.rb",
    "schemas/**/*.xsd",
    "schemas/README.md",
    "examples/fa3_{minimal,typical,full}.xml",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt",
    "NOTICE"
  ]
  tracked = Dir.chdir(__dir__) { `git ls-files -z 2>/dev/null`.split("\x0") }
  spec.files = tracked.empty? ? packaged : packaged & tracked
  spec.require_paths = ["lib"]

  # Runtime dependencies.
  spec.add_dependency "base64", "~> 0.2"           # not a default gem on Ruby 3.4+
  spec.add_dependency "bigdecimal", ">= 3.1"       # invoice amounts; not a default gem on Ruby 3.4+
  spec.add_dependency "connection_pool", ">= 2.4"  # resets the keep-alive pool in a forked child
  spec.add_dependency "faraday", "~> 2.5"          # HTTP layer (JSON + raw bytes)
  # The default adapter: keep-alive, one TLS handshake per host instead of per request. 2.3.1 requires
  # net-http-persistent >= 4.0.4, which works with connection_pool's after-fork reset.
  spec.add_dependency "faraday-net_http_persistent", "~> 2.3", ">= 2.3.1"
  spec.add_dependency "logger", ">= 1.5" # not a default gem on Ruby 4.0+
  # XML / XAdES / C14N canonicalization; 1.19.1 carries the libxml2 security fixes (C14N among them) and
  # SyntaxError#path, which Validator#errors reports.
  spec.add_dependency "nokogiri", ">= 1.19.1", "< 2"
  spec.add_dependency "rubyzip", "~> 3.4" # ZIP packages (batch / export); < 3.4 has CVE-2026-85396
  # openssl, digest — stdlib (AES, RSA-OAEP, RSASSA-PSS, ECDSA, ECDH, PKCS#10)

  # rqrcode and minitar are optional (QR / tar.gz) — loaded lazily, not as hard dependencies.
  spec.add_development_dependency "minitar", "~> 0.9"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rqrcode", "~> 2.0"
  spec.add_development_dependency "rspec", "~> 3.12"
  # Pinned to a minor release: new RuboCop minors add or tighten cops and would turn CI red
  # without any code change. Bump deliberately.
  spec.add_development_dependency "rubocop", "~> 1.91.0"
  spec.add_development_dependency "webmock", "~> 3.19"
end
