# frozen_string_literal: true

require "aws-sdk-s3"
require "digest"
require "open3"
require "pathname"
require "set"
require "shellwords"

require "m3u8"

require_relative "codecs"
require_relative "instrumentation"
require_relative "lock"
require_relative "manifest"
require_relative "state"
require_relative "uploader"

module HLS
  # Base class for declarative HLS video profiles.
  #
  # Subclasses use the class-level DSL to describe their renditions, codec,
  # and storage. An instance binds the profile to a single input file and
  # drives the encode → upload → manifest pipeline.
  #
  # Example:
  #
  #   class CourseVideo < HLS::ApplicationVideo
  #     bucket "videos"
  #     signing_ttl 3600
  #     segment_duration 4
  #
  #     rendition :full,   scale: 1.0
  #     rendition :medium, scale: 0.5
  #     rendition :small,  scale: 0.25
  #   end
  #
  #   CourseVideo.new(input: HLS::Input.new("lecture.mp4"),
  #                   output: Pathname.new("tmp/out")).command
  class ApplicationVideo
    PLAYLIST = "index.m3u8"

    Rendition = Data.define(:width, :height, :bitrate)

    # A class-level rendition declaration. Resolved against an input at
    # instance time to a concrete Rendition.
    Declaration = Data.define(:name, :scale, :width, :height, :bitrate) do
      def scaled? = !scale.nil?

      def resolve(input:, bits_per_pixel:, max_bitrate_kbps:)
        if scaled?
          w = (input.width  * scale).floor
          h = (input.height * scale).floor
          Rendition.new(width: w, height: h, bitrate: estimate_bitrate(w, h, bits_per_pixel, max_bitrate_kbps))
        else
          Rendition.new(width: width, height: height, bitrate: bitrate)
        end
      end

      private

      def estimate_bitrate(width, height, bits_per_pixel, max_kbps)
        raw_kbps = (width * height * bits_per_pixel) / 1000.0
        # Round up to the nearest 100kbps, then cap.
        rounded = (raw_kbps / 100.0).ceil * 100
        [rounded, max_kbps].min
      end
    end

    # A poster declaration. Resolved against an input at instance time
    # to a concrete dimension pair. Filename is `<name>.jpg`.
    PosterDeclaration = Data.define(:name, :scale, :width, :height) do
      def filename
        "#{name}.jpg"
      end

      def resolve(input:)
        if scale
          w = (input.width  * scale).floor
          h = (input.height * scale).floor
          [w, h]
        else
          [width, height]
        end
      end
    end

    # Friendly names for the bits-per-pixel ratios. Subclasses may also
    # pass an integer directly.
    BITS_PER_PIXEL = {
      screencast: 3,  # Static content: presentations, tutorials, minimal motion
      mixed:      4,  # Moderate motion: typical web videos, interviews
      motion:     6   # High motion: action videos, sports, fast-paced content
    }.freeze

    UNSET = Object.new.freeze
    private_constant :UNSET

    class << self
      # Defines a class-level inheritable attribute. Subclasses fall back to
      # the parent's value until they set their own. Reads with no args,
      # writes with one.
      def class_setting(name, default: nil, coerce: nil)
        ivar = :"@#{name}"

        define_singleton_method(name) do |value = UNSET|
          if UNSET.equal?(value)
            if instance_variable_defined?(ivar)
              instance_variable_get(ivar)
            elsif superclass.respond_to?(name)
              superclass.public_send(name)
            else
              default
            end
          else
            instance_variable_set(ivar, coerce ? coerce.call(value) : value)
          end
        end
      end

      def renditions
        @renditions ||= []
      end

      # Declare a rendition. Two forms:
      #
      #   rendition :name, scale: 0.5
      #   rendition width: 1280, height: 720, bitrate: 1500
      def rendition(name = nil, scale: nil, width: nil, height: nil, bitrate: nil)
        if scale.nil? && (width.nil? || height.nil? || bitrate.nil?)
          raise ArgumentError,
            "rendition requires either `scale:` or all of `width:`, `height:`, `bitrate:`"
        end

        renditions << Declaration.new(
          name: name, scale: scale,
          width: width, height: height, bitrate: bitrate
        )
      end

      # Replace any inherited rendition declarations with a fresh list.
      # Useful when a subclass needs to start over rather than extend the
      # parent's renditions.
      def reset_renditions!
        @renditions = []
      end

      def posters
        @posters ||= []
      end

      # Declare a poster image. Two forms:
      #
      #   poster :hero,      scale: 1.0
      #   poster :thumbnail, width: 320, height: 180
      #
      # Each declaration produces `<name>.jpg` in the output directory.
      # If no posters are declared, the encode step produces no posters.
      def poster(name, scale: nil, width: nil, height: nil)
        if scale.nil? && (width.nil? || height.nil?)
          raise ArgumentError,
            "poster requires either `scale:` or both `width:` and `height:`"
        end

        posters << PosterDeclaration.new(
          name: name, scale: scale, width: width, height: height
        )
      end

      def reset_posters!
        @posters = []
      end

      def inherited(subclass)
        super
        # Each subclass starts with a copy of the parent's renditions
        # and posters. Subclass mutations don't leak back to the parent.
        subclass.instance_variable_set(:@renditions, renditions.map(&:itself))
        subclass.instance_variable_set(:@posters, posters.map(&:itself))
      end

      # Returns a read-side Manifest bound to this profile's bucket and
      # signing TTL. The host app's controller uses this to serve signed
      # playlists.
      #
      #   CourseVideo.manifest("phlex/forms/overview").master_playlist
      def manifest(path, expires_in: signing_ttl, cache: manifest_cache, cache_ttl: manifest_cache_ttl)
        Manifest.new(
          bucket: resolve_bucket,
          path: path,
          expires_in: expires_in,
          segment_duration: segment_duration,
          variant_uri: method(:variant_uri),
          cache: cache,
          cache_ttl: cache_ttl
        )
      end

      # Maps a manifest's S3 path + ffmpeg variant index to the URI that
      # appears in the master playlist for that variant. Override on a
      # subclass to fit a non-default URL scheme:
      #
      #   class CustomVideo < HLS::ApplicationVideo
      #     def self.variant_uri(path:, variant_index:)
      #       "/streams/#{path}/v/#{variant_index}.m3u8"
      #     end
      #   end
      #
      # The default returns `<basename(path)>/<variant_index>.m3u8`,
      # which is relative to the master playlist's URL and matches a
      # `/videos/*path/:id/:variant.m3u8` Rails route.
      def variant_uri(path:, variant_index:)
        "#{::File.basename(path)}/#{variant_index}.m3u8"
      end

      # Resolves the configured bucket value to a usable bucket object.
      #
      # Accepts:
      #   - An Aws::S3::Bucket directly
      #   - A non-empty string name (resolved through `HLS.s3_resource`)
      #   - Any object that responds to `object(key)` and yields a
      #     duck-typed object implementing the storage protocol
      #     (see HLS::Storage)
      #
      # The duck-typing escape hatch lets host apps swap in alternative
      # backends — MinIO, GCS, an in-memory adapter for tests — without
      # the gem hardcoding the AWS SDK.
      def resolve_bucket
        case bucket
        when Aws::S3::Bucket
          bucket
        when String
          raise missing_bucket_error if bucket.empty?
          HLS.s3_resource.bucket(bucket)
        when nil
          raise missing_bucket_error
        else
          return bucket if bucket.respond_to?(:object)
          raise ArgumentError, "Unsupported bucket value: #{bucket.inspect} " \
            "(expected Aws::S3::Bucket, a String, or any object responding to #object(key))"
        end
      end

      private

      def missing_bucket_error
        ArgumentError.new(
          "#{name || self} has no bucket configured. " \
          "Set one with `bucket \"my-bucket\"` in the profile class or " \
          "via Rails.application.config.hls.bucket."
        )
      end
    end

    class_setting :bucket
    class_setting :signing_ttl,      default: 3600
    class_setting :segment_duration, default: 4
    class_setting :audio_codec,      default: "aac"
    class_setting :audio_bitrate,    default: 128
    class_setting :video_codec,      default: :h264
    class_setting :max_bitrate_kbps, default: 15_000
    # Hard cap (in seconds) on a single ffmpeg invocation. nil disables.
    # On timeout the process gets SIGTERM, then SIGKILL after a grace
    # period, and HLS::Error is raised. Tune this to roughly 2-3× the
    # longest video you intend to encode.
    class_setting :ffmpeg_timeout, default: nil

    # Optional cache backend used by the read-side Manifest to avoid
    # repeated S3 GETs for hot playlists. Anything implementing
    # `fetch(key, expires_in:) { ... }` (Rails.cache fits) works.
    class_setting :manifest_cache, default: nil
    class_setting :manifest_cache_ttl, default: Manifest::DEFAULT_CACHE_TTL
    class_setting :bits_per_pixel,
      default: BITS_PER_PIXEL.fetch(:mixed),
      coerce: ->(v) { v.is_a?(Symbol) ? BITS_PER_PIXEL.fetch(v) : Integer(v) }

    attr_reader :input, :output, :key_prefix

    # input::      An HLS::Input (or anything that responds to width/height/path)
    # output::     Pathname for the local working directory ffmpeg writes to
    # key_prefix:: Where the bundle lives in the bucket. Defaults to the
    #              output directory's basename.
    def initialize(input:, output:, key_prefix: nil)
      @input = input
      @output = Pathname.new(output)
      @key_prefix = key_prefix || @output.basename.to_s
    end

    # Run the full pipeline: encode + posters (if input changed or
    # output is missing) then upload to the bucket. Idempotent —
    # re-running with an unchanged input + intact output is a no-op.
    #
    # Returns the uploader's result hash: `{ uploaded: N, skipped: N }`.
    def process
      output.mkpath
      result = nil
      HLS::Instrumentation.instrument(:process,
        profile: self.class.name, output: output.to_s, key_prefix: key_prefix
      ) do |payload|
        HLS::Lock.acquire(output) do
          state = HLS::State.load(output)

          unless encoded?(state)
            encode!
            poster! if self.class.posters.any?
            verify_encode!
            state.record_encode(
              input_digest: input_digest,
              profile: self.class.name,
              renditions: renditions.map(&:to_h)
            )
            state.save
          end

          result = HLS::Uploader.new(
            bucket: self.class.resolve_bucket,
            output: output,
            key_prefix: key_prefix,
            state: state
          ).perform

          payload&.merge!(result) if payload
        end
      end
      result
    end

    # Walks the just-encoded output directory and asserts the bundle is
    # well-formed: master + variants + segments + declared posters all
    # exist and are non-empty. Raises HLS::Error with a list of problems
    # if anything is missing — better to fail before recording state and
    # uploading than to leave a half-written bundle on the bucket.
    def verify_encode!
      HLS::Instrumentation.instrument(:verify, profile: self.class.name, output: output.to_s) do
        problems = []

        master = output.join(PLAYLIST)
        unless master.exist?
          raise HLS::Error, "encode produced no master playlist at #{master}"
        end

        master_list = M3u8::Reader.new.read(master.read)
        if master_list.items.empty?
          problems << "master playlist has no variant streams"
        end

        master_list.items.each do |variant_item|
          variant_path = output.join(variant_item.uri)
          unless variant_path.exist?
            problems << "variant playlist missing: #{variant_item.uri}"
            next
          end

          variant_list = M3u8::Reader.new.read(variant_path.read)
          if variant_list.items.empty?
            problems << "variant #{variant_item.uri} has no segments"
          end

          variant_list.items.each do |segment_item|
            segment_path = variant_path.dirname.join(segment_item.segment)
            unless segment_path.exist? && segment_path.size > 0
              problems << "segment missing or empty: #{variant_item.uri} → #{segment_item.segment}"
            end
          end
        end

        self.class.posters.each do |declaration|
          poster_path = output.join(declaration.filename)
          unless poster_path.exist? && poster_path.size > 0
            problems << "declared poster missing or empty: #{declaration.filename}"
          end
        end

        next if problems.empty?

        raise HLS::Error,
          "encode produced an invalid bundle at #{output}:\n  - " + problems.join("\n  - ")
      end
    end

    # Runs ffmpeg to produce the HLS multiplex. Raises on non-zero exit.
    def encode!
      input.validate! if input.respond_to?(:validate!)
      HLS::Instrumentation.instrument(:encode,
        profile: self.class.name,
        output: output.to_s,
        renditions: renditions.map(&:to_h)
      ) do
        run_ffmpeg(command)
      end
    end

    # Runs ffmpeg to produce all declared posters in one decode pass.
    # No-op when no posters are declared.
    def poster!
      return if self.class.posters.empty?
      input.validate! if input.respond_to?(:validate!)
      HLS::Instrumentation.instrument(:poster,
        profile: self.class.name,
        output: output.to_s,
        count: self.class.posters.size
      ) do
        run_ffmpeg(poster_command)
      end
    end

    # ffmpeg command that produces all declared posters in one decode pass.
    def poster_command
      cmd = ["ffmpeg", "-y", "-i", input.path.to_s]
      self.class.posters.each do |declaration|
        w, h = declaration.resolve(input: input)
        cmd += [
          "-vf", "scale=w=#{w}:h=#{h}:force_original_aspect_ratio=decrease",
          "-frames:v", "1",
          output.join(declaration.filename).to_s
        ]
      end
      cmd
    end

    # SHA256 digest of the input file. Used by the state sidecar to detect
    # when the source has changed.
    def input_digest
      @input_digest ||= "sha256:#{Digest::SHA256.file(input.path.to_s).hexdigest}"
    end

    # Renditions resolved against this instance's input.
    def renditions
      @renditions ||= self.class.renditions.map do |declaration|
        declaration.resolve(
          input: input,
          bits_per_pixel: self.class.bits_per_pixel,
          max_bitrate_kbps: self.class.max_bitrate_kbps
        )
      end
    end

    # Renditions whose width fits within the input. We never upscale.
    def downscaleable_renditions
      renditions.select { |r| r.width <= input.width }
    end

    def exist?
      output.join(PLAYLIST).exist?
    end

    def command
      [
        "ffmpeg",
        "-y",
        "-i", input.path.to_s,
        "-filter_complex", filter_complex
      ] + video_maps + audio_maps + [
        "-f", "hls",
        "-var_stream_map", stream_map,
        "-master_pl_name", PLAYLIST,
        "-hls_time", self.class.segment_duration.to_s,
        "-hls_playlist_type", "vod",
        "-hls_segment_filename", segment_pattern,
        playlist_pattern
      ]
    end

    private

    # An "encoded" state requires both the sidecar saying so AND the
    # master playlist actually being on disk. Without the file check
    # we'd happily skip encode and try to upload nothing if someone
    # wiped the output dir but left state.json behind.
    def encoded?(state)
      state.encoded?(input_digest: input_digest) &&
        output.join(PLAYLIST).exist?
    end

    # Maximum number of stderr characters preserved in the error message.
    # ffmpeg's stderr can be hundreds of KB on a real failure; the tail is
    # where the actual error lives.
    FFMPEG_STDERR_TAIL = 2_000
    private_constant :FFMPEG_STDERR_TAIL

    # Seconds between SIGTERM and SIGKILL when timing out a stuck ffmpeg.
    FFMPEG_KILL_GRACE = 3
    private_constant :FFMPEG_KILL_GRACE

    def run_ffmpeg(args)
      output.mkpath
      cmd = args.map(&:to_s)
      timeout = self.class.ffmpeg_timeout

      stderr_text, status, timed_out = capture_with_timeout(cmd, timeout: timeout)
      return if status&.success?

      tail = stderr_text.to_s.strip
      tail = "...#{tail[-FFMPEG_STDERR_TAIL..]}" if tail.length > FFMPEG_STDERR_TAIL

      if timed_out
        raise HLS::Error,
          "ffmpeg timed out after #{timeout}s: #{Shellwords.join(cmd)}\n" \
          "stderr:\n#{tail}"
      end

      raise HLS::Error,
        "ffmpeg failed (exit #{status&.exitstatus}): #{Shellwords.join(cmd)}\n" \
        "stderr:\n#{tail}"
    end

    # Runs cmd, capturing stderr. With a non-nil timeout, kills the
    # process if it overruns. Returns [stderr, status, timed_out].
    def capture_with_timeout(cmd, timeout:)
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        # Drain stdout in a background thread so a chatty ffmpeg can't
        # block on a full pipe buffer.
        stdout_thread = Thread.new { stdout.read }
        stderr_thread = Thread.new { stderr.read }

        if timeout && !wait_thr.join(timeout)
          terminate_pid(wait_thr.pid)
          stdout_thread.kill
          stderr_thread.kill
          return [stderr_thread.value.to_s, wait_thr.value, true]
        end

        [stderr_thread.value, wait_thr.value, false]
      end
    end

    def terminate_pid(pid)
      Process.kill("TERM", pid)
      deadline = Time.now + FFMPEG_KILL_GRACE
      until Time.now > deadline
        return if Process.waitpid(pid, Process::WNOHANG)
        sleep 0.1
      end
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # Process already gone — nothing to do.
    end

    def filter_complex
      n = downscaleable_renditions.size
      split = "[0:v]split=#{n}#{(1..n).map { |i| "[v#{i}]" }.join}"
      scaled = downscaleable_renditions.each_with_index.map do |rendition, i|
        "[v#{i + 1}]scale='if(gt(iw,#{rendition.width}),#{rendition.width},iw)':'if(gt(iw,#{rendition.width}),-2,ih)'[v#{i + 1}out]"
      end
      ([split] + scaled).join("; ")
    end

    def resolved_video_codec
      @resolved_video_codec ||= HLS::Codecs.resolve(self.class.video_codec)
    end

    def video_maps
      codec = resolved_video_codec
      gop = gop_size
      downscaleable_renditions.each_with_index.flat_map do |rendition, i|
        [
          "-map", "[v#{i + 1}out]",
          "-c:v:#{i}", codec,
          "-b:v:#{i}", "#{rendition.bitrate}k",
          "-maxrate:v:#{i}", "#{(rendition.bitrate * 1.1).to_i}k",
          "-bufsize:v:#{i}", "#{(rendition.bitrate * 2).to_i}k",
          "-g", gop.to_s,
          "-keyint_min", gop.to_s,
          "-sc_threshold", "0"
        ] + video_codec_options(codec, i)
      end
    end

    # GOP size = framerate × segment_duration. This forces a keyframe
    # exactly at every segment boundary, which is required for HLS
    # players to seek to a segment without buffering a stray P/B-frame
    # chain. Without this scaling, a custom segment_duration (e.g., 2s
    # or 6s) would produce segments that don't start with a keyframe and
    # players would stall on seeks.
    def gop_size
      fps = input.respond_to?(:framerate) ? input.framerate : Input::DEFAULT_FRAMERATE
      fps * self.class.segment_duration
    end

    def video_codec_options(codec, index)
      case codec.to_s
      when "h264_videotoolbox"
        []
      when "libx264"
        [
          "-profile:v:#{index}", "high",
          "-level:v:#{index}", "4.1",
          "-preset:v:#{index}", "slow",
          "-tune:v:#{index}", "animation"
        ]
      else
        []
      end
    end

    def audio_maps
      codec = self.class.audio_codec
      bitrate = self.class.audio_bitrate
      downscaleable_renditions.each_with_index.flat_map do |_, i|
        [
          "-map", "a:0",
          "-c:a:#{i}", codec,
          "-b:a:#{i}", "#{bitrate}k",
          "-ac", "2"
        ]
      end
    end

    def stream_map
      downscaleable_renditions.each_index.map { |i| "v:#{i},a:#{i}" }.join(" ")
    end

    def variant_dir
      output.join("%v")
    end

    def segment_pattern
      variant_dir.join("%d.ts").to_s
    end

    def playlist_pattern
      variant_dir.join(PLAYLIST).to_s
    end
  end
end
