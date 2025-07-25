# frozen_string_literal: true

require_relative "hls/version"
require "shellwords"
require "pathname"
require "json"
require "m3u8"

module HLS
  class Error < StandardError; end

  class Poster
    attr_reader :input, :output, :width, :height

    def initialize(input:, output:, width:, height:)
      @input = input
      @output = output.join("poster.jpg")
      @width = width
      @height = height
    end

    def command
      [
        # invoke ffmpeg
        "ffmpeg",
        # overwrite output files without confirmation
        "-y",
        # input video file
        "-i", input,
        # scale video to target resolution
        "-vf", "scale=w=#{width}:h=#{height}:force_original_aspect_ratio=decrease",
        # extract only one frame
        "-frames:v", "1",
        # output file path
        output
      ]
    end
  end

  module Video
    class Base
      attr_accessor :input, :output, :renditions

      PLAYLIST = "index.m3u8".freeze

      Rendition = Data.define(:width, :height, :bitrate)

      def initialize(input:, output:)
        @input = Input.new(input)
        @output = output
        @renditions = []
      end

      def downscaleable_renditions
        @renditions.select { |r| r.width <= input.width }
      end

      def rendition(...)
        @renditions << Rendition.new(...)
      end

      def command
        [
          "ffmpeg",
          "-y",
          "-i", @input.path,
          "-filter_complex", filter_complex
        ] + \
        video_maps + \
        audio_maps + \
        [
          "-f", "hls",
          "-var_stream_map", stream_map,
          "-master_pl_name", PLAYLIST,
          "-hls_time", "4",
          "-hls_playlist_type", "vod",
          "-hls_segment_filename", segment,
          playlist
        ]
      end

      private

      def filter_complex
        n = downscaleable_renditions.size
        split = "[0:v]split=#{n}#{(1..n).map { |i| "[v#{i}]" }.join}"
        scaled = downscaleable_renditions.each_with_index.map do |rendition, i|
          "[v#{i + 1}]scale='if(gt(iw,#{rendition.width}),#{rendition.width},iw)':'if(gt(iw,#{rendition.width}),-2,ih)'[v#{i + 1}out]"
        end
        ([split] + scaled).join("; ")
      end

      def video_maps(codec: "h264_videotoolbox")
        downscaleable_renditions.each_with_index.flat_map do |rendition, i|
          [
            "-map", "[v#{i + 1}out]",
            "-c:v:#{i}", codec,
            "-b:v:#{i}", "#{rendition.bitrate}k"
          ]
        end
      end

      def audio_maps(codec: "aac", bitrate: 128)
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

      def variant
        @output.join("%v")
      end

      def segment
        variant.join("%d.ts").to_s
      end

      def playlist
        variant.join(PLAYLIST).to_s
      end
    end

    class Web < Base
      def initialize(...)
        super(...)
        # 360p - Low quality for mobile/slow connections
        rendition width: 640,  height: 360,  bitrate: 500
        # 480p - Standard definition for basic streaming
        rendition width: 854,  height: 480,  bitrate: 1000
        # 720p - High definition for most desktop viewing
        rendition width: 1280, height: 720,  bitrate: 3000
        # 1080p - Full HD for high-quality streaming
        rendition width: 1920, height: 1080, bitrate: 6000
        # 4K - Ultra HD for premium viewing experience
        rendition width: 3840, height: 2160, bitrate: 12000
      end
    end

    # Do very little work on vidoes so I can get more dev cycles in.
    class Dev < Base
      def initialize(...)
        super(...)
        # 360p - Low quality for mobile/slow connections
        rendition width: 640,  height: 360,  bitrate: 500
      end
    end
  end

  class Input
    attr_reader :path, :json

    def initialize(path)
      @path = Pathname(path)
    end

    def json
      @json ||= probe
    end

    def width      = stream.dig(:width)
    def height     = stream.dig(:height)
    def codec      = stream.dig(:codec_name)
    def duration   = json.dig(:format, :duration)&.to_f
    def framerate  = parse_rate(stream.dig(:r_frame_rate))

    private

    def stream
      json.dig(:streams, 0)
    end

    def probe
      raw = `ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,r_frame_rate,codec_name \
        -show_entries format=duration \
        -of json "#{@path}"`

      JSON.parse(raw, symbolize_names: true)
    end

    def parse_rate(rate)
      return unless rate
      num, den = rate.split("/").map(&:to_f)
      return if den.zero?
      (num / den).round(3)
    end
  end

  class Directory
    def initialize(source)
      @source = Pathname.new(source)
    end

    def glob(glob)
      Enumerator.new do |y|
        @source.glob(glob).each do |input|
          relative = input.relative_path_from(@source)
          output = relative.dirname.join(relative.basename(input.extname))
          y << [ input, output ]
        end
      end
    end
  end
end
