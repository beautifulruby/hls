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
        # Start the ffmpeg program to process video/audio files
        "ffmpeg",
        # Automatically overwrite output files if they already exist
        "-y",
        # Specify the input video file to read from
        "-i", input,
        # Apply video filter to resize the video while maintaining aspect ratio
        "-vf", "scale=w=#{width}:h=#{height}:force_original_aspect_ratio=decrease",
        # Extract only the first frame to create a still image
        "-frames:v", "1",
        # Save the extracted frame to this output file path
        output
      ]
    end
  end

  module Video
    # Video quality presets with recommended bitrates (kilobits per second)
    #
    # Bitrate determines how much data is used per second of video - higher bitrates
    # mean better quality but larger file sizes and more bandwidth needed for streaming.
    # These values are industry-standard recommendations for different resolutions.
    module Bitrates
      UHD_4K   = 15_000  # Ultra HD 4K (3840x2160) - Premium quality for large screens
      QHD_1440 = 9_000   # Quad HD (2560x1440) - High quality for gaming/professional use
      HD_1080  = 5_000   # Full HD (1920x1080) - Standard high-definition quality
      HD_720   = 2_500   # HD Ready (1280x720) - Basic high-definition quality
      SD_480   = 1_200   # Standard Definition (854x480) - DVD-like quality
      SD_360   = 800     # Low Definition (640x360) - Mobile/slow connection quality
    end

    # Bits per pixel ratios for different content types
    #
    # Different video content needs different amounts of data per pixel to look good.
    # Motion-heavy content (action movies, sports) needs more bits per pixel than
    # static content (screencasts, presentations) to avoid compression artifacts.
    # These multipliers help calculate appropriate bitrates based on content type.
    module BitsPerPixel
      SCREENCAST = 3  # Static content: presentations, tutorials, minimal motion
      MIXED      = 4  # Moderate motion: typical web videos, interviews
      MOTION     = 6  # High motion: action videos, sports, fast-paced content
    end

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
          # Start the ffmpeg program to process video/audio files
          "ffmpeg",
          # Automatically overwrite output files if they already exist
          "-y",
          # Specify the input video file to read from
          "-i", @input.path,
          # Use complex video filtering to create multiple scaled versions of the video
          "-filter_complex", filter_complex
        ] + \
        video_maps + \
        audio_maps + \
        [
          # Set output format to HLS (HTTP Live Streaming) for web streaming
          "-f", "hls",
          # Define which video and audio streams belong together for each quality level
          "-var_stream_map", stream_map,
          # Set the filename for the main playlist that lists all quality options
          "-master_pl_name", PLAYLIST,
          # Make each video segment 4 seconds long for smooth streaming
          "-hls_time", "4",
          # Set playlist type for complete videos (not live streams)
          "-hls_playlist_type", "vod",
          # Define naming pattern for individual video segment files
          "-hls_segment_filename", segment,
          # Save the playlist files to this location
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
            # Use the scaled video stream from the filter for this quality level
            "-map", "[v#{i + 1}out]",
            # Use H.264 codec to compress the video (widely supported format)
            "-c:v:#{i}", codec,
            # Set the target data rate for the video in kilobits per second
            "-b:v:#{i}", "#{rendition.bitrate}k",
            # Prevent bitrate from exceeding 110% of target to avoid buffering issues
            "-maxrate:v:#{i}", "#{(rendition.bitrate * 1.1).to_i}k",
            # Set buffer size for smooth data rate control during encoding
            "-bufsize:v:#{i}", "#{(rendition.bitrate * 2).to_i}k",
            # Insert keyframes every 180 frames to align with 6-second segments at 30fps
            "-g", "180",
            # Enforce minimum gap of 180 frames between keyframes for consistency
            "-keyint_min", "180",
            # Ignore scene changes when placing keyframes to maintain regular intervals
            "-sc_threshold", "0",
            # Use H.264 high profile for better compression and quality
            "-profile:v:#{i}", "high",
            # Set H.264 level 4.1 for compatibility with most devices and players
            "-level:v:#{i}", "4.1",
            # Use slow encoding preset for better compression at cost of encoding time
            "-preset:v:#{i}", "slow",
            # Optimize encoding for animated content, text, and UI elements
            "-tune:v:#{i}", "animation"
          ]
        end
      end

      def audio_maps(codec: "aac", bitrate: 128)
        downscaleable_renditions.each_with_index.flat_map do |_, i|
          [
            # Use the first audio track from the input file
            "-map", "a:0",
            # Use AAC codec to compress audio (widely supported format)
            "-c:a:#{i}", codec,
            # Set the audio data rate to 128 kilobits per second
            "-b:a:#{i}", "#{bitrate}k",
            # Convert audio to stereo (2 channels) for consistent playback
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

    # Encodes a video at the full size, half size, and quarter size for
    # reasonable streaming quality.
    class Scalable < Base
      BITS_PER_PIXEL = HLS::Video::BitsPerPixel::SCREENCAST
      MAX_BITRATE_KBPS = HLS::Video::Bitrates::UHD_4K

      def initialize(...)
        super(...)

        scaled_rendition 1.0
        scaled_rendition 0.5
        scaled_rendition 0.25
      end

      private

      def scaled_rendition(scale)
        width  = (input.width  * scale).floor
        height = (input.height * scale).floor
        bitrate = capped estimated_bitrate(width, height)

        rendition width:, height:, bitrate:
      end

      def estimated_bitrate(width, height)
        pixels = width * height
        raw_kbps = (pixels * BITS_PER_PIXEL) / 1000.0
        # Round up to the nearest 100kbps
        (raw_kbps / 100.0).ceil * 100
      end

      def capped(bitrate_kbps)
        [bitrate_kbps, MAX_BITRATE_KBPS].min
      end
    end

    # Do very little work on vidoes so I can get more dev cycles in.
    class VTechWatch < Base
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
    def bitrate    = stream.dig(:bit_rate)
    def codec      = stream.dig(:codec_name)
    def duration   = json.dig(:format, :duration)&.to_f

    private

    def stream
      json.dig(:streams, 0)
    end

    def probe
      raw = `ffprobe -v error -select_streams v:0 \
        -show_entries stream \
        -show_entries format \
        -of json "#{@path}"`

      JSON.parse(raw, symbolize_names: true)
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
