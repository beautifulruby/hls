# frozen_string_literal: true

# HLS gem configuration. Sets the Aws::S3::Resource the gem talks to.
# Per-profile bucket / signing TTL / segment duration live on the
# profile classes themselves under app/videos/.

require "aws-sdk-s3"

HLS.s3_resource = Aws::S3::Resource.new(
  access_key_id:     ENV.fetch("VIDEO_AWS_ACCESS_KEY_ID"),
  secret_access_key: ENV.fetch("VIDEO_AWS_SECRET_ACCESS_KEY"),
  endpoint:          ENV.fetch("VIDEO_S3_ENDPOINT_URL"),
  region:            ENV.fetch("VIDEO_AWS_REGION", "auto")
)
