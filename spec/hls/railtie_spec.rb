# frozen_string_literal: true

require "spec_helper"
require_relative "../support/dummy_rails_app"
require "rails"
require "hls/railtie"

# Verifies that profile classes under spec/dummy/app/videos autoload
# correctly when running inside a real Rails app.

RSpec.describe HLS::Railtie do
  before(:all) do
    @app = DummyRailsApp.boot!
  end

  it "registers app/videos in the autoload paths" do
    videos_path = @app.root.join("app", "videos").to_s
    expect(@app.config.autoload_paths).to include(videos_path)
    expect(@app.config.eager_load_paths).to include(videos_path)
  end

  it "autoloads ApplicationVideo from app/videos/application_video.rb" do
    klass = ::ApplicationVideo
    expect(klass).to be < HLS::ApplicationVideo
    expect(klass.bucket).to eq("dummy-bucket")
    expect(klass.signing_ttl).to eq(1800)
  end

  it "autoloads CourseVideo from app/videos/course_video.rb" do
    klass = ::CourseVideo
    expect(klass).to be < ::ApplicationVideo
    expect(klass.renditions.size).to eq(2)
    expect(klass.bucket).to eq("dummy-bucket") # inherited from ApplicationVideo
  end

  it "applies app config defaults to HLS::ApplicationVideo" do
    expect(HLS::ApplicationVideo.bucket).to eq("from-config")
  end

  it "applies values set inside config/initializers/hls.rb after :load_config_initializers" do
    # spec/dummy/config/initializers/hls.rb sets signing_ttl = 7200.
    # If the Railtie ran before :load_config_initializers, this would
    # still be the default 3600.
    expect(HLS::ApplicationVideo.signing_ttl).to eq(7200)
  end

  it "lets a subclass override the app-wide bucket default" do
    expect(::ApplicationVideo.bucket).to eq("dummy-bucket")
  end
end

RSpec.describe HLS::Railtie, ".apply_config (env-var-shaped configs)" do
  let(:cfg) { ActiveSupport::OrderedOptions.new }
  let(:target) do
    Class.new(HLS::ApplicationVideo).tap do |k|
      k.bucket "preset-bucket"
      k.audio_codec "preset-aac"
      k.signing_ttl 1234
    end
  end

  it "ignores empty-string values rather than overriding profile defaults" do
    # The realistic mistake: ENV.fetch("VIDEO_S3_BUCKET_NAME", "")
    # returns "" when the env var is missing. Empty string is truthy
    # in Ruby, so a naive `if cfg.bucket` would clobber the preset
    # bucket with garbage.
    cfg.bucket = ""
    cfg.audio_codec = ""

    described_class.apply_config(target, cfg)

    expect(target.bucket).to eq("preset-bucket")
    expect(target.audio_codec).to eq("preset-aac")
  end

  it "ignores nil values" do
    cfg.bucket = nil
    described_class.apply_config(target, cfg)
    expect(target.bucket).to eq("preset-bucket")
  end

  it "applies legitimately-present values" do
    cfg.bucket = "real-bucket"
    cfg.signing_ttl = 9999
    described_class.apply_config(target, cfg)
    expect(target.bucket).to eq("real-bucket")
    expect(target.signing_ttl).to eq(9999)
  end

  describe ".present?" do
    it "treats nil as absent" do
      expect(described_class.present?(nil)).to be(false)
    end

    it "treats empty-string as absent" do
      expect(described_class.present?("")).to be(false)
    end

    it "treats other strings as present" do
      expect(described_class.present?("x")).to be(true)
    end

    it "treats false as present (someone explicitly disabling something)" do
      expect(described_class.present?(false)).to be(true)
    end

    it "treats 0 as present" do
      expect(described_class.present?(0)).to be(true)
    end
  end
end
