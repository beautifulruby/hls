# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

module HLS
  # An input video file. Probes its metadata via ffprobe lazily (the first
  # time you ask for `width`, `height`, etc.) and caches the result.
  class Input
    PROBE_ARGS = %w[
      -v error
      -select_streams v:0
      -show_entries stream
      -show_entries format
      -of json
    ].freeze

    # Fallback framerate when ffprobe doesn't report one (rare, but
    # possible for some containers / streams). 30fps is the safe choice
    # for web video — common for screencasts and matches most uploads.
    DEFAULT_FRAMERATE = 30

    attr_reader :path

    def initialize(path)
      @path = Pathname.new(path)
    end

    def width    = video_stream[:width]
    def height   = video_stream[:height]
    def bitrate  = video_stream[:bit_rate]
    def codec    = video_stream[:codec_name]
    def duration = json.dig(:format, :duration)&.to_f

    # Frames per second as a Float. ffprobe reports framerate as a
    # rational ("30000/1001"); we resolve it to a float and round to the
    # nearest int. Returns DEFAULT_FRAMERATE if the input doesn't
    # advertise a usable framerate.
    def framerate
      raw = video_stream[:avg_frame_rate] || video_stream[:r_frame_rate]
      return DEFAULT_FRAMERATE if raw.nil? || raw.empty? || raw == "0/0"

      num, den = raw.split("/").map(&:to_f)
      return DEFAULT_FRAMERATE if den.nil? || den.zero?
      (num / den).round
    end

    def json
      @json ||= probe
    end

    # Returns true if ffprobe found a usable video stream. False for
    # audio-only files, malformed media, or anything missing pixel
    # dimensions.
    def video?
      stream = json.dig(:streams, 0)
      !!(stream && stream[:width] && stream[:height])
    end

    # Raises HLS::Error if the input is not a video. Call this before
    # handing an Input to the encode pipeline if you want to fail fast
    # with a clear message rather than waiting for ffmpeg to choke.
    def validate!
      return self if video?
      raise HLS::Error,
        "#{@path} has no video stream — ffprobe found " \
        "#{json[:streams]&.size || 0} stream(s) but none with width/height. " \
        "Audio-only files and non-media files are not supported."
    end

    private

    # Returns the first video stream's metadata, or raises HLS::Error if
    # there is none. We don't return an empty hash silently — `width`
    # returning nil leads to obscure crashes deeper in the pipeline.
    def video_stream
      json.dig(:streams, 0) or raise HLS::Error,
        "#{@path} has no video stream (ffprobe returned no streams matching v:0)"
    end

    def probe
      raise HLS::Error, "input file not found: #{@path}" unless @path.exist?

      stdout, stderr, status = Open3.capture3("ffprobe", *PROBE_ARGS, @path.to_s)
      unless status.success?
        raise HLS::Error, "ffprobe failed for #{@path}: #{stderr.strip}"
      end

      JSON.parse(stdout, symbolize_names: true)
    end
  end
end
