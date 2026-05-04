# frozen_string_literal: true

require "rails/railtie"

module HLS
  # Railtie that wires HLS into a host Rails app.
  #
  # - Registers `app/videos` as an autoload + eager-load path so that
  #   profile classes like `app/videos/course_video.rb` are picked up by
  #   Zeitwerk.
  # - Fires the `:hls_application_video` load hook so initializers can
  #   write `ActiveSupport.on_load(:hls_application_video) { ... }` to
  #   configure profiles in a reload-safe way.
  # - Lazily loads HLS::EncodeJob when ActiveJob is loaded.
  #
  # There is intentionally no `Rails.application.config.hls.*` config
  # bag — configure HLS::ApplicationVideo subclasses directly via their
  # class-level DSL inside the load hook. Less indirection, no shadow
  # schema, typos raise instead of being silently ignored.
  class Railtie < Rails::Railtie
    initializer "hls.autoload_paths", before: :set_autoload_paths do |app|
      videos_path = app.root.join("app", "videos")
      app.config.autoload_paths   << videos_path.to_s
      app.config.eager_load_paths << videos_path.to_s
    end

    initializer "hls.load_hook", after: :load_config_initializers do
      # Fire the load hook for any initializer that subscribed to it.
      # Subscribers run with `self` set to HLS::ApplicationVideo, so
      # they can call the class-level DSL directly:
      #
      #   ActiveSupport.on_load(:hls_application_video) do
      #     bucket           ENV.fetch("VIDEO_S3_BUCKET_NAME")
      #     signing_ttl      1.hour
      #     segment_duration 4
      #   end
      ActiveSupport.run_load_hooks(:hls_application_video, HLS::ApplicationVideo)
    end

    initializer "hls.encode_job" do
      ActiveSupport.on_load(:active_job) do
        require "hls/encode_job"
      end
    end
  end
end
