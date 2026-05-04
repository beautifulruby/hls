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

  private

  # Override libx264's `-preset slow` with `ultrafast` for tests.
  # We're verifying the gem can drive ffmpeg through to a valid HLS
  # bundle, not the encoded quality — fast preset trims real-ffmpeg
  # specs from ~8s to under 2s.
  def video_codec_options(codec, index)
    return ["-preset:v:#{index}", "ultrafast"] if codec.to_s == "libx264"
    super
  end
end
