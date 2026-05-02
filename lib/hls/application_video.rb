# frozen_string_literal: true

require "aws-sdk-s3"
require "digest"
require "pathname"
require "set"
require "shellwords"

require_relative "codecs"
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
      def manifest(path, expires_in: signing_ttl)
        Manifest.new(
          bucket: resolve_bucket,
          path: path,
          expires_in: expires_in,
          segment_duration: segment_duration
        )
      end

      # Resolves the configured bucket value to an Aws::S3::Bucket.
      # Accepts an Aws::S3::Bucket directly, or a non-empty string name
      # (resolved through `HLS.s3_resource`).
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
          raise ArgumentError, "Unsupported bucket value: #{bucket.inspect}"
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
      state = HLS::State.load(output)

      unless encoded?(state)
        encode!
        poster! if self.class.posters.any?
        state.record_encode(
          input_digest: input_digest,
          profile: self.class.name,
          renditions: renditions.map(&:to_h)
        )
        state.save
      end

      HLS::Uploader.new(
        bucket: self.class.resolve_bucket,
        output: output,
        key_prefix: key_prefix,
        state: state
      ).perform
    end

    # Runs ffmpeg to produce the HLS multiplex. Raises on non-zero exit.
    def encode!
      run_ffmpeg(command)
    end

    # Runs ffmpeg to produce all declared posters in one decode pass.
    # No-op when no posters are declared.
    def poster!
      return if self.class.posters.empty?
      run_ffmpeg(poster_command)
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

    def run_ffmpeg(args)
      output.mkpath
      cmd = args.map(&:to_s)
      unless system(*cmd)
        raise HLS::Error, "ffmpeg failed (exit #{$?.exitstatus}): #{Shellwords.join(cmd)}"
      end
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
      downscaleable_renditions.each_with_index.flat_map do |rendition, i|
        [
          "-map", "[v#{i + 1}out]",
          "-c:v:#{i}", codec,
          "-b:v:#{i}", "#{rendition.bitrate}k",
          "-maxrate:v:#{i}", "#{(rendition.bitrate * 1.1).to_i}k",
          "-bufsize:v:#{i}", "#{(rendition.bitrate * 2).to_i}k",
          "-g", "180",
          "-keyint_min", "180",
          "-sc_threshold", "0"
        ] + video_codec_options(codec, i)
      end
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
