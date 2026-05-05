# frozen_string_literal: true

require "aws-sdk-s3"

require_relative "hls/version"

module HLS
  class Error < StandardError; end

  class << self
    # The Aws::S3::Resource the gem uses when an HLS::Storage::S3
    # adapter is configured by `bucket_name:` (and resolves the bucket
    # lazily through this resource). Set in `config/initializers/hls.rb`:
    #
    #   HLS.s3_resource = Aws::S3::Resource.new(...)
    #
    # Storage::S3 instances may also pass `s3_resource:` directly to
    # bypass this default.
    attr_writer :s3_resource

    def s3_resource
      @s3_resource ||= Aws::S3::Resource.new
    end
  end
end

require_relative "hls/codecs"
require_relative "hls/instrumentation"
require_relative "hls/lock"
require_relative "hls/state"
require_relative "hls/storage"
require_relative "hls/cache"
require_relative "hls/uploader"
require_relative "hls/manifest"
require_relative "hls/input"
require_relative "hls/directory"
require_relative "hls/application_video"

# Optional Railtie — only loaded when running under Rails.
require_relative "hls/railtie" if defined?(Rails::Railtie)
