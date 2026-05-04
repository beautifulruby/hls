# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "active_support/isolated_execution_state"
require "generators/hls/video/video_generator"
require_relative "../support/minitest_shims"

RSpec.describe Hls::Generators::VideoGenerator, type: :generator do
  include MinitestShims
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  self.generator_class  = Hls::Generators::VideoGenerator
  self.destination_root = File.expand_path("../tmp/video-generator", __dir__)
  self.default_arguments = []

  before do
    prepare_destination
    # Stand-in ApplicationVideo so the generated subclass has something
    # to inherit from when we load it.
    stub_const("ApplicationVideo", Class.new(HLS::ApplicationVideo))
  end

  describe "filename derivation" do
    it "writes app/videos/<name>_video.rb from a CamelCase name" do
      run_generator ["Course"]
      assert_file "app/videos/course_video.rb"
    end

    it "underscores multi-word names" do
      run_generator ["BlogPost"]
      assert_file "app/videos/blog_post_video.rb"
    end

    it "strips a trailing 'Video' suffix instead of duplicating it" do
      run_generator ["CourseVideo"]
      assert_file "app/videos/course_video.rb"
      assert_no_file "app/videos/course_video_video.rb"
    end
  end

  describe "generated file content" do
    before { run_generator ["Course"] }

    it "inherits from ApplicationVideo with the right class name" do
      assert_file "app/videos/course_video.rb" do |content|
        expect(content).to include("class CourseVideo < ApplicationVideo")
      end
    end

    it "includes the rendition ladder" do
      assert_file "app/videos/course_video.rb" do |content|
        expect(content).to match(/rendition\s+:high,\s+scale: 1\.0/)
        expect(content).to match(/rendition\s+:medium,\s+scale: 0\.5/)
        expect(content).to match(/rendition\s+:small,\s+scale: 0\.25/)
      end
    end

    it "ships an active hero poster and commented examples for others" do
      assert_file "app/videos/course_video.rb" do |content|
        expect(content).to match(/^  poster :hero,/)
        expect(content).to match(/^  # poster :thumbnail,/)
      end
    end

    it "documents per-profile overrides as commented hints" do
      assert_file "app/videos/course_video.rb" do |content|
        expect(content).to include("# bits_per_pixel")
        expect(content).to include("# video_codec")
        expect(content).to include("# segment_duration")
      end
    end

    it "interpolates the class name into the docstring example" do
      assert_file "app/videos/course_video.rb" do |content|
        expect(content).to include("CourseVideo.new(")
        expect(content).to include("CourseVideo.manifest(")
      end
    end
  end

  describe "behavior of the generated profile when loaded" do
    # The behavior test that the user actually cares about: after we
    # generate the file, can we load it and get a working profile that
    # an HLS encode pipeline would accept?
    it "produces a class with the expected renditions and posters" do
      run_generator ["Course"]
      load File.join(destination_root, "app/videos/course_video.rb")

      expect(::CourseVideo.superclass).to eq(::ApplicationVideo)
      expect(::CourseVideo.renditions.map(&:name)).to eq([:high, :medium, :small])
      expect(::CourseVideo.posters.map(&:name)).to eq([:hero])
    ensure
      Object.send(:remove_const, :CourseVideo) if defined?(::CourseVideo)
    end

    it "produces a class whose .manifest method works against a Memory storage" do
      run_generator ["Lecture"]
      load File.join(destination_root, "app/videos/lecture_video.rb")

      ::LectureVideo.storage(HLS::Storage::Memory.new(name: "test"))
      manifest = ::LectureVideo.manifest("foo/bar")
      expect(manifest).to be_a(HLS::Manifest)
      expect(manifest.path).to eq("foo/bar")
    ensure
      Object.send(:remove_const, :LectureVideo) if defined?(::LectureVideo)
    end
  end
end
