# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "lib/deadlock_rpc"

Gem::Specification.new do |spec|
  spec.name          = "deadlock-rpc-ruby"
  spec.version       = DeadlockRpc::VERSION
  spec.authors       = ["Buntato"]
  spec.summary       = "Discord Rich Presence for Deadlock (Ruby Edition)"
  spec.description   = "Zero-dependency Ruby port of deadlock-rpc providing automatic Discord Rich Presence for Deadlock via -condebug console log parsing."
  spec.homepage      = "https://github.com/buntatoes/deadlock-rpc-ruby"
  spec.license       = "GPL-3.0-only"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files         = Dir["LICENSE", "README.md", "bin/*", "lib/**/*.rb", "assets/*"]
  spec.bindir        = "bin"
  spec.executables   = ["deadlock-rpc"]
  spec.require_paths = ["lib"]
end
