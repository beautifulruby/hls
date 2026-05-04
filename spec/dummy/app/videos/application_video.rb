# frozen_string_literal: true

class ApplicationVideo < HLS::ApplicationVideo
  def self.storage = HLS::Storage::S3.new(
    bucket_name: "dummy-bucket",
    signing_ttl: 1800
  )
end
