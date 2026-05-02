# frozen_string_literal: true

# Boots a single Rails app for the entire test run. Shared by every
# spec that needs to exercise the Railtie or run code in a Rails
# context. Rails freezes `autoload_paths` after initialize!, so we
# cannot boot more than once.
#
# Usage:
#
#   require_relative "../support/dummy_rails_app"
#   DummyRailsApp.boot!
#
# Subsequent calls are no-ops.

module DummyRailsApp
  def self.boot!
    return if defined?(@app) && @app

    require "rails"
    require "active_support"
    require "active_support/all"
    require "active_job"
    require "hls/railtie"
    require "hls/encode_job"

    app_class = Class.new(Rails::Application) do
      config.eager_load = false
      config.root = Pathname.new(File.expand_path("../dummy", __dir__))
      config.hosts.clear
      config.secret_key_base = "test"
      config.hls.bucket = "from-config"
      config.logger = Logger.new(IO::NULL)
    end

    Object.const_set(:DummyApplication, app_class)
    @app = app_class.initialize!
    @app
  end

  def self.app
    @app
  end
end
