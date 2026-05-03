# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/hls/video/video_generator"

RSpec.describe Hls::Generators::VideoGenerator, type: :generator do
  around do |example|
    Dir.mktmpdir do |tmp|
      @destination = Pathname.new(tmp)
      example.run
    end
  end

  def generate(name)
    described_class.start([name], destination_root: @destination.to_s)
  end

  it "scaffolds app/videos/<name>_video.rb from a CamelCase name" do
    generate("Course")
    file = @destination.join("app/videos/course_video.rb")
    expect(file).to exist
  end

  it "scaffolds with the right class name and inheritance" do
    generate("Course")
    body = @destination.join("app/videos/course_video.rb").read
    expect(body).to include("class CourseVideo < ApplicationVideo")
  end

  it "underscores multi-word names" do
    generate("BlogPost")
    expect(@destination.join("app/videos/blog_post_video.rb")).to exist
  end

  it "strips a trailing 'Video' suffix instead of duplicating it" do
    # `g hls:video CourseVideo` should not produce course_video_video.rb.
    generate("CourseVideo")
    expect(@destination.join("app/videos/course_video.rb")).to exist
    expect(@destination.join("app/videos/course_video_video.rb")).not_to exist
  end

  it "ships a sensible default rendition ladder" do
    generate("Course")
    body = @destination.join("app/videos/course_video.rb").read
    expect(body).to match(/rendition\s+:high,\s+scale: 1\.0/)
    expect(body).to match(/rendition\s+:medium,\s+scale: 0\.5/)
    expect(body).to match(/rendition\s+:small,\s+scale: 0\.25/)
  end

  it "ships an active hero poster and commented examples for others" do
    generate("Course")
    body = @destination.join("app/videos/course_video.rb").read
    expect(body).to match(/^  poster :hero,/)
    expect(body).to match(/^  # poster :thumbnail,/)
  end

  it "documents per-profile overrides as commented hints" do
    generate("Course")
    body = @destination.join("app/videos/course_video.rb").read
    expect(body).to include("# bits_per_pixel")
    expect(body).to include("# video_codec")
    expect(body).to include("# segment_duration")
  end

  it "inserts the class name into the docstring example" do
    generate("Lecture")
    body = @destination.join("app/videos/lecture_video.rb").read
    expect(body).to include("LectureVideo.new(")
    expect(body).to include("LectureVideo.manifest(")
  end
end
