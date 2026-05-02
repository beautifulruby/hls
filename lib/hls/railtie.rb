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

    initializer "hls.autoload_paths", before: :set_autoload_paths do |app|
      videos_path = app.root.join("app", "videos")
      app.config.autoload_paths       << videos_path.to_s
      app.config.eager_load_paths     << videos_path.to_s
    end

    initializer "hls.apply_config", after: :load_config_initializers do |app|
      cfg = app.config.hls
      HLS.s3_resource = cfg.s3_resource if cfg.s3_resource

      ActiveSupport.on_load(:hls_application_video) do
        bucket           cfg.bucket           if cfg.bucket
        signing_ttl      cfg.signing_ttl      if cfg.signing_ttl
        segment_duration cfg.segment_duration if cfg.segment_duration
        video_codec      cfg.video_codec      if cfg.video_codec
        audio_codec      cfg.audio_codec      if cfg.audio_codec
        audio_bitrate    cfg.audio_bitrate    if cfg.audio_bitrate
        bits_per_pixel   cfg.bits_per_pixel   if cfg.bits_per_pixel
        max_bitrate_kbps cfg.max_bitrate_kbps if cfg.max_bitrate_kbps
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
