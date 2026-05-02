# frozen_string_literal: true

require "aws-sdk-s3"

require_relative "hls/version"

module HLS
  class Error < StandardError; end

  class << self
    # The Aws::S3::Resource the gem uses when a profile's `bucket` is
    # configured as a string name. Host apps configure this via the
    # Railtie:
    #
    #   Rails.application.config.hls.s3_resource = Aws::S3::Resource.new(...)
    #
    # In plain-Ruby usage:
    #
    #   HLS.s3_resource = Aws::S3::Resource.new(...)
    attr_writer :s3_resource

    def s3_resource
      @s3_resource ||= Aws::S3::Resource.new
    end
  end
end

require_relative "hls/codecs"
require_relative "hls/state"
require_relative "hls/uploader"
require_relative "hls/manifest"
require_relative "hls/input"
require_relative "hls/directory"
require_relative "hls/application_video"

# Optional Railtie — only loaded when running under Rails.
require_relative "hls/railtie" if defined?(Rails::Railtie)
