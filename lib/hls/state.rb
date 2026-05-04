# frozen_string_literal: true

require "json"
require "pathname"
require "time"

module HLS
  # Sidecar state for an encoded bundle. Records the input digest,
  # rendition list, and per-file upload status so a re-run can skip work
  # that's already done and a crashed run can resume from the last
  # successful upload.
  #
  # Lives at `<output>/.hls-state.json` next to the encoded bundle.
  class State
    FILENAME = ".hls-state.json"

    class CorruptError < HLS::Error; end

    def self.load(output_dir)
      path = Pathname.new(output_dir).join(FILENAME)
      new(path: path, data: read(path))
    end

    # Reads state JSON from disk. Returns `default_data` for a missing
    # file (the common first-run case). Raises CorruptError when the
    # file exists but isn't parseable — silently re-encoding on
    # corruption would be expensive and surprising; explicit failure
    # lets the caller decide whether to delete the sidecar and retry.
    def self.read(path)
      return default_data unless path.exist?

      raw = JSON.parse(path.read, symbolize_names: true)
      default_data.merge(raw)
    rescue JSON::ParserError => e
      raise CorruptError, "state file at #{path} is not valid JSON: #{e.message}"
    end

    def self.default_data
      {
        input_digest: nil,
        config_digest: nil,
        profile: nil,
        renditions: [],
        encoded_at: nil,
        uploads: {}
      }
    end

    attr_reader :path

    def initialize(path:, data:)
      @path = Pathname.new(path)
      @data = data
    end

    def input_digest  = @data[:input_digest]
    def config_digest = @data[:config_digest]
    def profile       = @data[:profile]
    def renditions    = @data[:renditions]
    def encoded_at    = @data[:encoded_at]
    def uploads       = @data[:uploads]

    # Has this output already been encoded for the given input AND
    # profile config? A change to either invalidates the encode —
    # bumping `audio_bitrate` or adding a rendition has to re-run
    # ffmpeg even if the input file is byte-identical.
    def encoded?(input_digest:, config_digest:)
      !@data[:encoded_at].nil? &&
        @data[:input_digest]  == input_digest &&
        @data[:config_digest] == config_digest
    end

    # Has the file at relative_key already been uploaded with the given digest?
    def uploaded?(relative_key:, digest:)
      upload = @data[:uploads][relative_key.to_sym]
      !upload.nil? && upload[:digest] == digest
    end

    def record_encode(input_digest:, config_digest:, profile:, renditions:)
      @data[:input_digest]  = input_digest
      @data[:config_digest] = config_digest
      @data[:profile]       = profile
      @data[:renditions]    = renditions
      @data[:encoded_at]    = Time.now.utc.iso8601
      # Content has changed; previous upload records are stale.
      @data[:uploads]       = {}
    end

    def record_upload(relative_key:, digest:, etag: nil)
      @data[:uploads][relative_key.to_sym] = {
        digest: digest,
        etag: etag,
        uploaded_at: Time.now.utc.iso8601
      }
    end

    def save
      path.parent.mkpath
      path.write(JSON.pretty_generate(@data))
    end

    def to_h
      @data.dup
    end
  end
end
