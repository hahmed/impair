# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "impair"

require "minitest/autorun"
require_relative "support/echo"
require_relative "support/shared_relay_tests"
