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
