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

    attr_reader :path

    def initialize(path)
      @path = Pathname.new(path)
    end

    def width    = stream[:width]
    def height   = stream[:height]
    def bitrate  = stream[:bit_rate]
    def codec    = stream[:codec_name]
    def duration = json.dig(:format, :duration)&.to_f

    def json
      @json ||= probe
    end

    private

    def stream
      json.dig(:streams, 0) || {}
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
