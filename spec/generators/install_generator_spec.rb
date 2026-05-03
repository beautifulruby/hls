# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/test_case"
require "active_support/isolated_execution_state"
require "active_support/core_ext/integer/time"
require "active_support/ordered_options"
require "generators/hls/install/install_generator"
require_relative "../support/minitest_shims"

# Generator specs use Rails' own test helpers (the same ones the
# Rails source uses to test its own generators). They give us:
#   - run_generator       — invokes the generator with the destination set
#   - prepare_destination — wipes and recreates the tmpdir
#   - assert_file         — assert created file path + content
#   - assert_no_file
RSpec.describe Hls::Generators::InstallGenerator, type: :generator do
  include MinitestShims
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  # Behavior expects these as class-level attributes, set up front.
  self.generator_class  = Hls::Generators::InstallGenerator
  self.destination_root = File.expand_path("../tmp/install-generator", __dir__)
  self.default_arguments = []

  before { prepare_destination }

  describe "config/initializers/hls.rb" do
    it "is created with the right Rails.application.config.hls wiring" do
      run_generator

      assert_file "config/initializers/hls.rb" do |content|
        expect(content).to include("Rails.application.config.hls.tap")
        expect(content).to include("hls.s3_resource = Aws::S3::Resource.new(")
        expect(content).to include("hls.bucket =")
        expect(content).to include("hls.signing_ttl = 1.hour")
        expect(content).to include("hls.segment_duration = 4")
      end
    end

    it "documents the optional knobs as commented examples" do
      run_generator

      assert_file "config/initializers/hls.rb" do |content|
        expect(content).to include("# hls.ffmpeg_timeout =")
        expect(content).to include("# hls.manifest_cache =")
      end
    end
  end

  describe "app/videos/application_video.rb" do
    it "is created with the right inheritance" do
      run_generator

      assert_file "app/videos/application_video.rb" do |content|
        expect(content).to include("class ApplicationVideo < HLS::ApplicationVideo")
      end
    end

    it "is a no-op until the developer uncomments overrides" do
      run_generator

      assert_file "app/videos/application_video.rb" do |content|
        inside = content[/class ApplicationVideo.*?\nend/m]
        active_lines = inside.lines
          .map(&:strip)
          .reject { |l| l.empty? || l.start_with?("#") || l =~ /\A(class|end)\b/ }
        expect(active_lines).to be_empty
      end
    end

    it "actually loads as Ruby and produces a class that inherits from HLS::ApplicationVideo" do
      # Behavior test: catches anything wrong with the template that a
      # text match wouldn't — a stray syntax error, a wrong constant
      # name, an inherits-from-the-wrong-thing typo.
      run_generator
      hide_const("ApplicationVideo") if defined?(::ApplicationVideo)
      load File.join(destination_root, "app/videos/application_video.rb")
      expect(::ApplicationVideo.superclass).to eq(HLS::ApplicationVideo)
    ensure
      Object.send(:remove_const, :ApplicationVideo) if defined?(::ApplicationVideo)
    end
  end

  describe "the generated initializer evaluated in a Rails-shaped context" do
    # Catches generator output that drifts from the Railtie's expected
    # config interface — the initializer touches `Rails.application
    # .config.hls.{bucket,signing_ttl,...}`, and if those names ever
    # rename, the template would produce a broken file that nothing
    # else tests.
    it "sets the config keys the Railtie reads, given the right env" do
      run_generator
      contents = File.read(File.join(destination_root, "config/initializers/hls.rb"))

      stub_env({
        "VIDEO_AWS_ACCESS_KEY_ID"     => "key",
        "VIDEO_AWS_SECRET_ACCESS_KEY" => "secret",
        "VIDEO_S3_ENDPOINT_URL"       => "https://example.com",
        "VIDEO_S3_BUCKET_NAME"        => "test-bucket"
      }) do
        fake_app = Object.new
        fake_app.define_singleton_method(:config) {
          @cfg ||= Object.new.tap do |c|
            c.instance_variable_set(:@hls, ActiveSupport::OrderedOptions.new)
            c.define_singleton_method(:hls) { @hls }
          end
        }

        rails_const = Object.new
        rails_const.define_singleton_method(:application) { fake_app }
        stub_const("Rails", rails_const)

        eval(contents, TOPLEVEL_BINDING.dup, "generated_hls_initializer.rb")

        expect(fake_app.config.hls.bucket).to eq("test-bucket")
        expect(fake_app.config.hls.signing_ttl).to eq(1.hour)
        expect(fake_app.config.hls.segment_duration).to eq(4)
        expect(fake_app.config.hls.s3_resource).to be_a(Aws::S3::Resource)
      end
    end

    def stub_env(env)
      original = env.keys.to_h { |k| [k, ENV[k]] }
      env.each { |k, v| ENV[k] = v }
      yield
    ensure
      original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
