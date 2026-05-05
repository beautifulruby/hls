# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "tmpdir"
require "uri"
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
    def generate_test_video(path: nil, duration: 12, width: 640, height: 360, framerate: 30, frequency: 440)
      path = Pathname.new(path || Dir::Tmpname.create(["hls-fixture", ".mp4"]) {})

      cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=duration=#{duration}:size=#{width}x#{height}:rate=#{framerate}",
        "-f", "lavfi", "-i", "sine=frequency=#{frequency}:duration=#{duration}",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
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
      stdout, _stderr, status = Open3.capture3(
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,codec_name",
        "-of", "json",
        path.to_s
      )
      raise HLS::Error, "ffprobe failed for #{path}" unless status.success?
      JSON.parse(stdout)
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

      # Asserts that the variant URIs in a master playlist resolve to
      # clean URLs when a player fetches the master at the given URL.
      # Catches the path-prefix-included-twice bug class:
      #
      #   it "rewrites variant URIs correctly" do
      #     manifest = CourseVideo.manifest("phlex/forms/overview")
      #     expect(manifest.master_playlist).to resolve_variants_under(
      #       "https://app.example.com/videos/phlex/forms/overview.m3u8"
      #     )
      #   end
      #
      # The rule: a *relative* variant URI must resolve to a URL whose
      # path extends the master URL's path-without-extension. If a
      # variant URI accidentally includes the master path as a prefix,
      # resolution against the master's parent directory loses that
      # prefix and the resolved URL no longer starts with the master
      # path — that's the doubling bug.
      #
      # Absolute variant URIs (different scheme/host) and path-absolute
      # URIs (starting with /) are skipped — those are intentional
      # routing decisions, not doubling.
      #
      # Pass `.matching(<regexp>)` to additionally assert the resolved
      # URLs match a specific shape:
      #
      #   .resolve_variants_under(url).matching(%r{/videos/.+/\d+\.m3u8\z})
      RSpec::Matchers.define :resolve_variants_under do |master_url|
        match do |playlist|
          @master_uri  = URI(master_url)
          @master_path_without_ext = @master_uri.path.sub(/\.m3u8\z/, "")
          @failures    = []

          unless playlist.respond_to?(:items)
            @failures << "expected an M3u8::Playlist, got #{playlist.class}"
            next false
          end

          if playlist.items.empty?
            @failures << "master playlist has no variant streams"
            next false
          end

          playlist.items.each_with_index do |item, i|
            variant_uri = URI(item.uri)
            resolved = (@master_uri + item.uri)

            # Skip checks for absolute URIs (different host or scheme)
            # and path-absolute URIs (starting with /). Those are
            # explicit routing choices, not bugs.
            relative = !variant_uri.absolute? && !item.uri.start_with?("/")

            if relative && !resolved.path.start_with?(@master_path_without_ext)
              @failures << "variant ##{i} URI #{item.uri.inspect} resolved to " \
                "#{resolved} — its path #{resolved.path.inspect} should " \
                "extend the master path #{@master_path_without_ext.inspect} " \
                "but does not. This usually means the variant URI " \
                "incorrectly includes a path prefix."
            end

            if @expected_pattern && !resolved.to_s.match?(@expected_pattern)
              @failures << "variant ##{i} resolved URL #{resolved.to_s.inspect} " \
                "did not match #{@expected_pattern.inspect}"
            end
          end

          @failures.empty?
        end

        chain :matching do |pattern|
          @expected_pattern = pattern
        end

        failure_message do
          "expected variant URIs to resolve cleanly under #{@master_uri}, but:\n  - " +
            @failures.join("\n  - ")
        end

        failure_message_when_negated do
          "expected variant URIs NOT to resolve cleanly under #{@master_uri}, but they did"
        end
      end
    end
  end
end
