# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = true
end

task default: :test
