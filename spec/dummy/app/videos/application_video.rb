# frozen_string_literal: true

class ApplicationVideo < HLS::ApplicationVideo
  def self.storage = HLS::Storage::S3.new(
    bucket_name: "dummy-bucket",
    signing_ttl: 1800
  )

  # Pin software h264 in the test bundle. Without this the codec
  # resolver picks h264_nvenc on Linux runners where ffmpeg is built
  # with NVENC support but no GPU is present, and ffmpeg crashes at
  # runtime with exit 255. libx264 always works.
  video_codec "libx264"
end
