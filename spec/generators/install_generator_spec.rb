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

  self.generator_class  = Hls::Generators::InstallGenerator
  self.destination_root = File.expand_path("../tmp/install-generator", __dir__)
  self.default_arguments = []

  before { prepare_destination }

  describe "config/initializers/hls.rb" do
    it "wires HLS.s3_resource and only that — no Rails config bag" do
      run_generator

      assert_file "config/initializers/hls.rb" do |content|
        expect(content).to include("HLS.s3_resource = Aws::S3::Resource.new(")
        expect(content).to include("ENV.fetch(\"VIDEO_AWS_ACCESS_KEY_ID\")")
        expect(content).not_to include("Rails.application.config.hls")
        expect(content).not_to include("on_load(:hls_application_video)")
      end
    end

    it "evaluates cleanly with the expected env vars set" do
      run_generator
      contents = File.read(File.join(destination_root, "config/initializers/hls.rb"))
      previous_resource = HLS.instance_variable_get(:@s3_resource)

      stub_env({
        "VIDEO_AWS_ACCESS_KEY_ID"     => "key",
        "VIDEO_AWS_SECRET_ACCESS_KEY" => "secret",
        "VIDEO_S3_ENDPOINT_URL"       => "https://example.com"
      }) do
        eval(contents, TOPLEVEL_BINDING.dup, "generated_hls_initializer.rb")
        expect(HLS.s3_resource).to be_a(Aws::S3::Resource)
      end
    ensure
      HLS.s3_resource = previous_resource
    end
  end

  describe "app/videos/application_video.rb" do
    it "is created with the right inheritance and a default storage" do
      run_generator

      assert_file "app/videos/application_video.rb" do |content|
        expect(content).to include("class ApplicationVideo < HLS::ApplicationVideo")
        expect(content).to include("def self.storage = HLS::Storage::S3.new(")
        expect(content).to include("ENV.fetch(\"VIDEO_S3_BUCKET_NAME\")")
        expect(content).to include("signing_ttl: 1.hour")
      end
    end

    it "loads as Ruby and produces a class that inherits from HLS::ApplicationVideo" do
      run_generator
      hide_const("ApplicationVideo") if defined?(::ApplicationVideo)
      load File.join(destination_root, "app/videos/application_video.rb")
      expect(::ApplicationVideo.superclass).to eq(HLS::ApplicationVideo)
    ensure
      Object.send(:remove_const, :ApplicationVideo) if defined?(::ApplicationVideo)
    end

    it "produces a class whose .storage returns a configured HLS::Storage::S3" do
      run_generator
      hide_const("ApplicationVideo") if defined?(::ApplicationVideo)
      load File.join(destination_root, "app/videos/application_video.rb")

      stub_env({ "VIDEO_S3_BUCKET_NAME" => "test-bucket" }) do
        s3 = ::ApplicationVideo.storage
        expect(s3).to be_a(HLS::Storage::S3)
        expect(s3.bucket_name).to eq("test-bucket")
        expect(s3.signing_ttl).to eq(1.hour)
      end
    ensure
      Object.send(:remove_const, :ApplicationVideo) if defined?(::ApplicationVideo)
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
