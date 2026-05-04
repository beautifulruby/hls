# frozen_string_literal: true

require "spec_helper"
require_relative "../support/dummy_rails_app"
require "rails"
require "hls/railtie"

# Verifies that profile classes under spec/dummy/app/videos autoload
# correctly when running inside a real Rails app, and that the
# :hls_application_video load hook fires after :load_config_initializers
# so an initializer can configure ApplicationVideo directly.

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
    # spec/dummy/app/videos/application_video.rb overrides the
    # app-wide bucket — subclass setter wins over the parent default.
    expect(klass.bucket).to eq("dummy-bucket")
  end

  it "autoloads CourseVideo from app/videos/course_video.rb" do
    klass = ::CourseVideo
    expect(klass).to be < ::ApplicationVideo
    expect(klass.renditions.size).to eq(2)
    expect(klass.bucket).to eq("dummy-bucket") # inherited from ApplicationVideo
  end

  it "fires :hls_application_video AFTER :load_config_initializers" do
    # spec/dummy/config/initializers/hls.rb subscribes to the load
    # hook and sets signing_ttl 7200. If the load hook fired before
    # initializers ran, this would still be the default 3600.
    expect(HLS::ApplicationVideo.signing_ttl).to eq(7200)
  end

  it "applies the app-wide bucket to HLS::ApplicationVideo via the load hook" do
    # The dummy app's boot subscribes to :hls_application_video and
    # sets `bucket "from-config"` on HLS::ApplicationVideo itself.
    # Subclasses inherit unless they override.
    expect(HLS::ApplicationVideo.bucket).to eq("from-config")
  end

  it "does not register a Rails.application.config.hls bag" do
    # Earlier versions exposed `config.hls = OrderedOptions.new` and
    # copied values onto ApplicationVideo via a second initializer.
    # That indirection is gone — configuration goes directly on the
    # class via the :hls_application_video load hook.
    expect(@app.config).not_to respond_to(:hls)
  end
end
