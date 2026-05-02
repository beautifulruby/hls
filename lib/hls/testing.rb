# frozen_string_literal: true

require "json"
require "pathname"
require "tmpdir"
require "m3u8"

module HLS
  # Public test helpers for verifying that an HLS profile actually
  # produces a correct bundle when run against ffmpeg. Users of the gem
  # can include this module in their own spec suites to write integration
  # tests against their `app/videos/*.rb` profile classes:
  #
  #   require "hls/testing"
  #
  #   RSpec.describe CourseVideo do
  #     include HLS::Testing
  #
  #     it "encodes a valid HLS bundle" do
  #       video = generate_test_video(duration: 12)
  #       output = Pathname.new(Dir.mktmpdir)
  #
  #       profile = CourseVideo.new(input: HLS::Input.new(video), output: output)
  #       silence_ffmpeg do
  #         profile.encode!
  #         profile.poster!
  #       end
  #
  #       expect(output).to be_a_valid_hls_bundle.with_variants(3)
  #     end
  #   end
  #
  # All helpers shell out to ffmpeg/ffprobe (already a hard dep of the
  # gem), so any environment that can run the gem can run these helpers.
  module Testing
    # Generates a deterministic test video at `path` (or a tmpdir-backed
    # path if not given). Returns the path. The video uses ffmpeg's
    # `testsrc` filter for video and `sine` for audio — fully
    # self-contained, no external assets.
    def generate_test_video(path: nil, duration: 12, width: 640, height: 360, frequency: 440)
      path = Pathname.new(path || Dir::Tmpname.create(["hls-fixture", ".mp4"]) {})

      cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=duration=#{duration}:size=#{width}x#{height}:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=#{frequency}:duration=#{duration}",
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "64k",
        "-shortest",
        path.to_s
      ]
      unless system(*cmd, out: File::NULL, err: File::NULL)
        raise HLS::Error, "ffmpeg failed to generate test fixture at #{path}"
      end

      path
    end

    # Probes a media file with ffprobe and returns its parsed metadata.
    def probe(path)
      raw = `ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name -of json "#{path}"`
      raise HLS::Error, "ffprobe failed for #{path}" unless $?.success?
      JSON.parse(raw)
    end

    # Returns [width, height] for an image or video file.
    def probe_dimensions(path)
      stream = probe(path).fetch("streams").first or
        raise HLS::Error, "no video stream in #{path}"
      [stream["width"], stream["height"]]
    end

    # Parses an m3u8 file and returns the M3u8::Playlist.
    def parse_playlist(path)
      M3u8::Reader.new.read(File.read(path))
    end

    # Silences stdout/stderr inside the block. Useful for hiding ffmpeg's
    # noisy progress output during test runs. Restores streams even on
    # exception.
    def silence_ffmpeg
      original_stdout = $stdout.dup
      original_stderr = $stderr.dup
      $stdout.reopen(File::NULL, "w")
      $stderr.reopen(File::NULL, "w")
      yield
    ensure
      $stdout.reopen(original_stdout) if original_stdout
      $stderr.reopen(original_stderr) if original_stderr
    end

    # RSpec matchers. Loaded automatically when RSpec is defined.
    if defined?(RSpec::Matchers)
      RSpec::Matchers.define :be_a_valid_hls_bundle do
        match do |dir|
          @dir = Pathname.new(dir)
          @failures = []

          unless @dir.directory?
            @failures << "#{@dir} is not a directory"
            next false
          end

          master_path = @dir.join("index.m3u8")
          unless master_path.exist?
            @failures << "missing master playlist at #{master_path}"
            next false
          end

          @master = M3u8::Reader.new.read(master_path.read)
          if @master.items.empty?
            @failures << "master playlist has no streams"
            next false
          end

          # Expected variant count, if specified.
          if @expected_variant_count && @master.items.size != @expected_variant_count
            @failures << "expected #{@expected_variant_count} variants, found #{@master.items.size}"
            next false
          end

          # Each variant playlist must exist on disk.
          @master.items.each do |item|
            variant_path = @dir.join(item.uri)
            unless variant_path.exist?
              @failures << "variant playlist missing on disk: #{item.uri}"
            end
          end

          # Each variant must have segment files.
          @master.items.each do |item|
            variant_path = @dir.join(item.uri)
            next unless variant_path.exist?

            playlist = M3u8::Reader.new.read(variant_path.read)
            playlist.items.each do |segment|
              segment_path = variant_path.dirname.join(segment.segment)
              unless segment_path.exist? && segment_path.size > 0
                @failures << "segment missing or empty: #{item.uri} → #{segment.segment}"
              end
            end
          end

          # Posters, if specified.
          (@expected_posters || []).each do |name|
            poster_path = @dir.join("#{name}.jpg")
            unless poster_path.exist? && poster_path.size > 0
              @failures << "expected poster missing or empty: #{name}.jpg"
            end
          end

          @failures.empty?
        end

        chain :with_variants do |count|
          @expected_variant_count = count
        end

        chain :with_posters do |*names|
          @expected_posters = names
        end

        failure_message do |dir|
          "expected #{dir} to be a valid HLS bundle, but:\n  - " + @failures.join("\n  - ")
        end

        failure_message_when_negated do |dir|
          "expected #{dir} not to be a valid HLS bundle, but it was"
        end
      end
    end
  end
end
