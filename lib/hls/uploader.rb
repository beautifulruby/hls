# frozen_string_literal: true

require "digest"
require "pathname"

module HLS
  # Walks an encoded HLS bundle and pushes each file to the configured
  # bucket. Idempotent and resumable: a state sidecar tracks per-file
  # MD5 digests, and files whose remote upload matches the local digest
  # are skipped.
  class Uploader
    CONTENT_TYPES = {
      ".m3u8" => "application/vnd.apple.mpegurl",
      ".ts"   => "video/MP2T",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".png"  => "image/png",
      ".vtt"  => "text/vtt"
    }.freeze

    CACHE_CONTROL_IMMUTABLE = "public, max-age=31536000, immutable"

    # VOD playlists are also immutable once written — segments don't
    # get rewritten, the playlist itself doesn't change. Use a shorter
    # max-age than the segments themselves so deploys can publish a
    # superseding bundle, but allow CDN caching at the playlist edge.
    CACHE_CONTROL_PLAYLIST = "public, max-age=300"

    attr_reader :bucket, :output, :key_prefix, :state

    def initialize(bucket:, output:, key_prefix:, state:)
      @bucket = bucket
      @output = Pathname.new(output)
      @key_prefix = key_prefix.to_s.sub(%r{\A/}, "").sub(%r{/\z}, "")
      @state = state
    end

    # Upload everything under the output directory that hasn't been
    # uploaded yet. Returns a hash with :uploaded and :skipped counts.
    def perform
      uploaded = 0
      skipped = 0

      uploadable_files.each do |file|
        relative_key = relative_key_for(file)
        digest = md5_of(file)

        if state.uploaded?(relative_key: relative_key, digest: digest)
          skipped += 1
          next
        end

        response = upload(file, relative_key: relative_key)
        state.record_upload(relative_key: relative_key, digest: digest, etag: response.etag)
        state.save
        uploaded += 1
      end

      { uploaded: uploaded, skipped: skipped }
    end

    private

    def upload(file, relative_key:)
      object = bucket.object(key_for(relative_key))
      object.put(
        body: file.open("rb"),
        content_type: content_type_for(file),
        cache_control: cache_control_for(file)
      )
    end

    def uploadable_files
      output.glob("**/*")
        .select { |p| p.file? }
        .reject { |p| skip?(p) }
        .sort
    end

    # Skip the state sidecar (we never upload it) and any junk dotfiles
    # macOS / editors leave behind (.DS_Store, ._*).
    def skip?(path)
      basename = path.basename.to_s
      basename == State::FILENAME ||
        basename == ".DS_Store" ||
        basename.start_with?("._")
    end

    def relative_key_for(file)
      file.relative_path_from(output).to_s
    end

    def key_for(relative_key)
      key_prefix.empty? ? relative_key : "#{key_prefix}/#{relative_key}"
    end

    def md5_of(file)
      Digest::MD5.file(file).hexdigest
    end

    def content_type_for(file)
      CONTENT_TYPES.fetch(file.extname.downcase, "application/octet-stream")
    end

    def cache_control_for(file)
      file.extname.downcase == ".m3u8" ? CACHE_CONTROL_PLAYLIST : CACHE_CONTROL_IMMUTABLE
    end
  end
end
