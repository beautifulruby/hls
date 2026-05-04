# frozen_string_literal: true

# HLS gem configuration. Configures the encoder/uploader/manifest
# objects directly — no Rails config indirection. Settings here become
# defaults for every HLS::ApplicationVideo subclass under app/videos/;
# subclasses can override individually with the same DSL.
#
# See https://github.com/beautifulruby/hls for the full reference.

require "aws-sdk-s3"

# The S3-compatible client. Works with AWS S3, Tigris, Cloudflare R2,
# MinIO, etc. For MinIO add `force_path_style: true`.
HLS.s3_resource = Aws::S3::Resource.new(
  access_key_id:     ENV.fetch("VIDEO_AWS_ACCESS_KEY_ID"),
  secret_access_key: ENV.fetch("VIDEO_AWS_SECRET_ACCESS_KEY"),
  endpoint:          ENV.fetch("VIDEO_S3_ENDPOINT_URL"),
  region:            ENV.fetch("VIDEO_AWS_REGION", "auto")
)

# The block runs each time ApplicationVideo is (re)loaded by Zeitwerk
# in development. Inside, `self` is HLS::ApplicationVideo, so you can
# call its class-level DSL directly. Settings cascade to every
# subclass under app/videos/.
ActiveSupport.on_load(:hls_application_video) do
  # Bucket where encoded HLS bundles live.
  bucket ENV.fetch("VIDEO_S3_BUCKET_NAME")

  # Pre-signed URL TTL. Players cache segments for the life of a play
  # session, so this only needs to outlast the longest video plus a
  # comfortable buffer.
  signing_ttl 1.hour

  # HLS segment length (seconds). 4 is a common sweet spot — short
  # enough for fast seek, long enough to keep segment count down.
  # Changing this triggers a re-encode of every profile.
  segment_duration 4

  # Hard cap on a single ffmpeg invocation. Useful when running on a
  # job runner that won't kill its own runaway processes.
  # ffmpeg_timeout 30.minutes

  # Optional: cache backend for read-side Manifest playlists. Cuts S3
  # GETs on hot videos. Anything implementing Rails.cache#fetch works.
  # manifest_cache Rails.cache
  # manifest_cache_ttl 5.minutes
end
