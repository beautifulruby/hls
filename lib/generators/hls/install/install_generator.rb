# frozen_string_literal: true

require "rails/generators/base"

module Hls
  module Generators
    # Bootstraps a host Rails app for the HLS gem:
    #   - config/initializers/hls.rb (bucket + S3 resource config)
    #   - app/videos/application_video.rb (base profile class)
    #
    # Usage:
    #
    #   bin/rails g hls:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_initializer
        template "initializer.rb", "config/initializers/hls.rb"
      end

      def create_application_video
        template "application_video.rb", "app/videos/application_video.rb"
      end

      def post_install_message
        say <<~MSG

          HLS installed.

          Next steps:
            1. Set the env vars referenced in config/initializers/hls.rb
               (VIDEO_AWS_ACCESS_KEY_ID, VIDEO_S3_BUCKET_NAME, etc.)
            2. Generate your first profile:
                 bin/rails g hls:video Course
            3. Encode + upload a video:
                 CourseVideo.new(input: HLS::Input.new("lecture.mp4"),
                                 output: Pathname.new("tmp/encoded")).process
        MSG
      end
    end
  end
end
