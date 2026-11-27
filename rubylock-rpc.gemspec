# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "lib/rubylock_rpc"

Gem::Specification.new do |spec|
  spec.name          = "rubylock-rpc"
  spec.version       = RubylockRpc::VERSION
  spec.authors       = ["Buntato"]
  spec.summary       = "RubyLock RPC — Discord Rich Presence for Deadlock"
  spec.description   = "Zero-dependency Ruby Discord Rich Presence client for Deadlock via -condebug console log parsing."
  spec.homepage      = "https://github.com/buntatoes/rubylock-rpc"
  spec.license       = "GPL-3.0-only"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files         = Dir["LICENSE", "README.md", "bin/*", "lib/**/*.rb", "assets/*"]
  spec.bindir        = "bin"
  spec.executables   = ["rubylock-rpc"]
  spec.require_paths = ["lib"]
end
