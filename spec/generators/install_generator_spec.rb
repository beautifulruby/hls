# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "active_support/isolated_execution_state"
require "active_support/core_ext/integer/time"
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
    it "configures HLS objects directly — no Rails config indirection" do
      run_generator

      assert_file "config/initializers/hls.rb" do |content|
        expect(content).to include("HLS.s3_resource = Aws::S3::Resource.new(")
        expect(content).to include("ActiveSupport.on_load(:hls_application_video)")
        expect(content).to include("bucket ENV.fetch(\"VIDEO_S3_BUCKET_NAME\")")
        expect(content).to include("signing_ttl 1.hour")
        expect(content).to include("segment_duration 4")
        expect(content).not_to include("Rails.application.config.hls")
      end
    end

    it "documents the optional knobs as commented examples" do
      run_generator

      assert_file "config/initializers/hls.rb" do |content|
        expect(content).to include("# ffmpeg_timeout")
        expect(content).to include("# manifest_cache")
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

  describe "the generated initializer evaluated end-to-end" do
    # Catches generator output that drifts from the gem's actual API:
    # we eval the initializer with real env vars, then trigger the
    # :hls_application_video load hook the same way the Railtie does
    # at boot time. If the template uses a renamed setting name or a
    # non-existent setter, this fails loudly.
    it "configures HLS.s3_resource and ApplicationVideo settings via the load hook" do
      run_generator
      contents = File.read(File.join(destination_root, "config/initializers/hls.rb"))

      stub_env({
        "VIDEO_AWS_ACCESS_KEY_ID"     => "key",
        "VIDEO_AWS_SECRET_ACCESS_KEY" => "secret",
        "VIDEO_S3_ENDPOINT_URL"       => "https://example.com",
        "VIDEO_S3_BUCKET_NAME"        => "test-bucket"
      }) do
        # Read the ivar directly — calling HLS.s3_resource would
        # eagerly construct a default Aws::S3::Resource and blow up
        # without an AWS_REGION set in this process.
        previous_resource = HLS.instance_variable_get(:@s3_resource)

        # The eval'd template includes an ActiveSupport.on_load
        # subscriber, which lingers globally. Snapshot and restore so
        # later specs that boot Rails don't get the test's stub block
        # firing against their app.
        load_hooks = ActiveSupport.instance_variable_get(:@load_hooks)
        previous_subscribers = (load_hooks[:hls_application_video] || []).dup

        target = Class.new(HLS::ApplicationVideo)
        stub_const("ApplicationVideo", target)

        eval(contents, TOPLEVEL_BINDING.dup, "generated_hls_initializer.rb")
        # The Railtie fires this after :load_config_initializers; we
        # simulate that step here.
        ActiveSupport.run_load_hooks(:hls_application_video, target)

        expect(HLS.s3_resource).to be_a(Aws::S3::Resource)
        expect(target.bucket).to eq("test-bucket")
        expect(target.signing_ttl).to eq(1.hour)
        expect(target.segment_duration).to eq(4)
      ensure
        HLS.s3_resource = previous_resource
        load_hooks[:hls_application_video] = previous_subscribers if load_hooks
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
