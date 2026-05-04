# frozen_string_literal: true

require "spec_helper"
require_relative "../support/dummy_rails_app"
require "rails"
require "hls/railtie"

# Verifies that profile classes under spec/dummy/app/videos autoload
# correctly when running inside a real Rails app, and that the
# Railtie doesn't introduce extra config indirection beyond
# autoload paths and the EncodeJob require.

RSpec.describe HLS::Railtie do
  before(:all) do
    @app = DummyRailsApp.boot!
  end

  it "registers app/videos in the autoload + eager-load paths" do
    videos_path = @app.root.join("app", "videos").to_s
    expect(@app.config.autoload_paths).to include(videos_path)
    expect(@app.config.eager_load_paths).to include(videos_path)
  end

  it "autoloads ApplicationVideo from app/videos/application_video.rb" do
    klass = ::ApplicationVideo
    expect(klass).to be < HLS::ApplicationVideo
    expect(klass.storage).to be_a(HLS::Storage::S3)
    expect(klass.storage.bucket_name).to eq("dummy-bucket")
    expect(klass.storage.signing_ttl).to eq(1800)
  end

  it "autoloads CourseVideo from app/videos/course_video.rb" do
    klass = ::CourseVideo
    expect(klass).to be < ::ApplicationVideo
    expect(klass.renditions.size).to eq(2)
    # Subclass inherits storage from ApplicationVideo without override.
    expect(klass.storage.bucket_name).to eq("dummy-bucket")
  end

  it "does not register a Rails.application.config.hls bag" do
    # Earlier versions exposed `config.hls = OrderedOptions.new` and
    # copied values onto ApplicationVideo via a second initializer.
    # Both are gone — configuration goes directly on the class.
    expect(@app.config).not_to respond_to(:hls)
  end
end
