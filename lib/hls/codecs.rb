# frozen_string_literal: true

require "open3"
require "set"

module HLS
  # Codec resolution for ffmpeg.
  #
  # A profile declares its codec in one of three forms:
  #
  #   video_codec :h264                  # logical, auto-resolved per host
  #   video_codec "libx264"              # explicit ffmpeg encoder name
  #   video_codec "h264_nvenc"           # explicit (cloud GPU)
  #
  # When the profile asks for a logical codec, this module picks the best
  # available encoder for the current host by consulting the ffmpeg
  # encoder list. The list is queried once and cached.
  module Codecs
    H264 = {
      videotoolbox: "h264_videotoolbox", # macOS hardware
      nvenc:        "h264_nvenc",        # NVIDIA GPU
      qsv:          "h264_qsv",          # Intel QuickSync
      libx264:      "libx264"            # software fallback
    }.freeze

    # Per-platform priority order for the :h264 logical codec. The first
    # encoder available on the host wins.
    H264_PRIORITY = {
      darwin: [:videotoolbox, :libx264],
      linux:  [:nvenc, :qsv, :libx264]
    }.freeze

    class UnknownEncoder < StandardError; end

    module_function

    # Resolves a `video_codec` value to an explicit ffmpeg encoder name.
    def resolve(value)
      case value
      when :h264
        resolve_h264
      when Symbol
        # Already a specific variant: :libx264, :nvenc, etc.
        H264.fetch(value) { raise UnknownEncoder, "Unknown codec symbol: #{value}" }
      when String
        value
      else
        raise ArgumentError, "Unsupported video_codec value: #{value.inspect}"
      end
    end

    # The set of encoders ffmpeg reports as available on this host. Cached
    # for the life of the process.
    def available_encoders
      @available_encoders ||= probe_encoders
    end

    # Reset the encoder cache. Useful in tests.
    def reset!
      @available_encoders = nil
    end

    def resolve_h264
      priority = H264_PRIORITY[platform] || [:libx264]
      encoder_name = priority
        .map { |sym| H264.fetch(sym) }
        .find { |name| available_encoders.include?(name) }

      encoder_name || "libx264"
    end

    def platform
      case RbConfig::CONFIG["host_os"]
      when /darwin/  then :darwin
      when /linux/   then :linux
      when /mswin|mingw|cygwin/ then :windows
      else :unknown
      end
    end

    def probe_encoders
      stdout, _stderr, status = Open3.capture3("ffmpeg", "-hide_banner", "-encoders")
      return Set.new unless status.success?

      stdout.lines.filter_map do |line|
        # Encoder lines look like:  V..... libx264               ...
        # Skip the header and metadata lines.
        next unless line =~ /\A [\sVAS\.][\sFSXBD\.]{5}\s+(\S+)/

        $1
      end.to_set
    end
  end
end
