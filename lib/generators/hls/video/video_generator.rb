# frozen_string_literal: true

require "rails/generators/named_base"

module Hls
  module Generators
    # Scaffolds a new video profile under app/videos/.
    #
    #   bin/rails g hls:video Course
    #   # => app/videos/course_video.rb
    #
    # The generated file inherits from `ApplicationVideo` and ships with
    # a sensible default rendition ladder, a hero poster, and inline
    # comments for the common knobs (alternative codecs, bitrate
    # tuning, additional posters). Edit the file to tune.
    class VideoGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_video_profile
        template "video.rb", File.join("app/videos", "#{file_name}_video.rb")
      end

      private

      # `Course` -> `course`, `BlogPost` -> `blog_post`. Strips a
      # trailing `Video` so `g hls:video CourseVideo` doesn't produce
      # `course_video_video.rb`.
      def file_name
        super.sub(/_video\z/, "")
      end

      def class_name
        "#{file_name.camelize}Video"
      end
    end
  end
end
