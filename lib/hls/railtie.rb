# frozen_string_literal: true

require "rails/railtie"

module HLS
  # Railtie that wires HLS into a host Rails app.
  #
  # - Registers `app/videos` as an autoload + eager-load path so that
  #   profile classes like `app/videos/course_video.rb` are picked up by
  #   Zeitwerk.
  # - Exposes `Rails.application.config.hls` for app-wide defaults
  #   that profile classes inherit.
  class Railtie < Rails::Railtie
    config.hls = ActiveSupport::OrderedOptions.new

    # Settings the host app can override via `config.hls.<setting>`.
    # Each name maps 1:1 to a `class_setting` on HLS::ApplicationVideo.
    APPLIED_SETTINGS = %i[
      bucket signing_ttl segment_duration video_codec audio_codec
      audio_bitrate bits_per_pixel max_bitrate_kbps ffmpeg_timeout
      manifest_cache manifest_cache_ttl
    ].freeze

    # Treat both nil and empty-string as "not set". Common pattern in
    # host apps: `hls.bucket = ENV.fetch("VIDEO_S3_BUCKET_NAME", "")` —
    # when the env var is missing, an empty string would otherwise
    # silently override a working value set in a profile class.
    def self.present?(value)
      !value.nil? && !(value.is_a?(String) && value.empty?)
    end

    # Apply config values to the given target class, skipping anything
    # that isn't "present" by the rule above. Extracted from the
    # initializer so it's directly unit-testable.
    def self.apply_config(target, cfg)
      APPLIED_SETTINGS.each do |name|
        value = cfg.public_send(name)
        target.public_send(name, value) if present?(value)
      end
    end

    initializer "hls.autoload_paths", before: :set_autoload_paths do |app|
      videos_path = app.root.join("app", "videos")
      app.config.autoload_paths       << videos_path.to_s
      app.config.eager_load_paths     << videos_path.to_s
    end

    initializer "hls.apply_config", after: :load_config_initializers do |app|
      cfg = app.config.hls
      HLS.s3_resource = cfg.s3_resource if cfg.s3_resource

      ActiveSupport.on_load(:hls_application_video) do
        HLS::Railtie.apply_config(self, cfg)
      end

      ActiveSupport.run_load_hooks(:hls_application_video, HLS::ApplicationVideo)
    end

    initializer "hls.encode_job" do
      ActiveSupport.on_load(:active_job) do
        require "hls/encode_job"
      end
    end
  end
end
