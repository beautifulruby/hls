# frozen_string_literal: true

# Base class for every video profile in this app. Defaults set here
# flow down to subclasses unless overridden. Per-profile classes live
# alongside this file at app/videos/<name>_video.rb — generate one
# with:
#
#   bin/rails g hls:video Course
#
class ApplicationVideo < HLS::ApplicationVideo
  # The storage backend. Defaulted to an S3 bucket configured from
  # env vars; signing TTL controls how long pre-signed URLs stay
  # valid. Override `storage` per-subclass to point at a different
  # bucket, swap in a different adapter, etc.
  def self.storage = HLS::Storage::S3.new(
    bucket_name: ENV.fetch("VIDEO_S3_BUCKET_NAME"),
    signing_ttl: 1.hour
  )

  # Examples of app-wide overrides. Uncomment to apply to every
  # subclass.
  #
  # video_codec      :h264          # auto-resolves the best encoder
  # audio_codec      "aac"
  # bits_per_pixel   :screencast    # :screencast (3), :mixed (4), :motion (6)
  # max_bitrate_kbps 15_000
  # segment_duration 4
end
