# frozen_string_literal: true

require "rails/railtie"

module HLS
  # Railtie that wires HLS into a host Rails app.
  #
  # - Registers `app/videos` as an autoload + eager-load path so that
  #   profile classes like `app/videos/course_video.rb` are picked up
  #   by Zeitwerk.
  # - Lazily loads HLS::EncodeJob when ActiveJob is loaded.
  #
  # That's it. There is intentionally no Rails.application.config.hls
  # config bag and no load hook to subscribe to. Configure profile
  # classes directly:
  #
  #   class ApplicationVideo < HLS::ApplicationVideo
  #     def self.storage = HLS::Storage::S3.new(
  #       bucket_name: ENV.fetch("VIDEO_S3_BUCKET_NAME"),
  #       signing_ttl: 1.hour
  #     )
  #     segment_duration 4
  #   end
  #
  # Zeitwerk reloads the class in dev so the settings re-apply
  # automatically; no special hook needed.
  class Railtie < Rails::Railtie
    initializer "hls.autoload_paths", before: :set_autoload_paths do |app|
      videos_path = app.root.join("app", "videos")
      app.config.autoload_paths   << videos_path.to_s
      app.config.eager_load_paths << videos_path.to_s
    end

    initializer "hls.encode_job" do
      ActiveSupport.on_load(:active_job) do
        require "hls/encode_job"
      end
    end
  end
end
