# frozen_string_literal: true

require_relative "hls/version"
require "shellwords"
require "pathname"

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

  class Video < Data.define(:input, :output, :width, :height, :bitrate)
    def maxrate = bitrate * 2
    def bufsize = bitrate * 2
    def segment = output.join("%03d.ts")
    def playlist = output.join("index.m3u8")

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
        # use Apple hardware-accelerated encoder
        "-c:v", "h264_videotoolbox",
        # average target video bitrate
        "-b:v", "#{bitrate}k",
        # cap video bitrate spikes (twice the target bitrate)
        "-maxrate", "#{maxrate}k",
        # buffer size for bitrate smoothing
        "-bufsize", "#{bufsize}k",
        # use AAC for audio
        "-c:a", "aac",
        # audio bitrate
        "-b:a", "128k",
        # audio sample rate
        "-ar", "48000",
        # set GOP size (e.g., 48 for 2s at 24fps)
        "-g", "48",
        # force minimum keyframe interval
        "-keyint_min", "48",
        # enable faststart for streaming before file is fully loaded
        "-movflags", "+faststart",
        # duration of each HLS segment in seconds
        "-hls_time", "4",
        # generate VOD-compatible HLS playlist
        "-hls_playlist_type", "vod",
        # pattern for naming segment files
        "-hls_segment_filename", segment,
        # output playlist file
        playlist
      ]
    end
  end

  class Rendition
    attr_reader :input, :output, :width, :height, :bitrate

    def initialize(input:, output:, width:, height:, bitrate:)
      @input = input
      @output = output
      @width = width
      @height = height
      @bitrate = bitrate
      @output = output.join(name)
    end

    def resolution = "#{width}x#{height}"
    def name = "#{height}p"

    def poster = Poster.new(input:, output:, width:, height:)
    def video = Video.new(input:, output:, width:, height:, bitrate:)
  end

  class Pool
    def initialize(workers: 4)
      @queue = Queue.new
      @shutdown = false
      @workers = Array.new(workers) do
        Thread.new do
          while !@shutdown && (job = @queue.pop)
            break if job.nil? || @shutdown
            job.call
          end
        end
      end
    end

    def schedule(&task)
      @queue << task unless @shutdown
    end

    def ffmpeg(task)
      shell(*task.command)
    end

    def shell(*command)
      return if @shutdown
      Shellwords.join(command).tap do
        puts it
        system it
      end
    end

    def shutdown
      @shutdown = true
      @workers.size.times { @queue << nil } # poison pills
    end

    def process
      @workers.size.times { @queue << nil } # poison pills
      @workers.each(&:join)
    end
  end

  class Package
    attr_reader :input, :output, :renditions

    def initialize(input:, output:)
      @input = input
      @output = output
      @renditions = []
    end

    def rendition(**)
      @renditions << Rendition.new(input:, output:, **)
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
