# frozen_string_literal: true

require "aws-sdk-s3"
require "m3u8"

module HLS
  # Reads an HLS bundle out of an S3-compatible bucket and returns
  # signed-URL playlists ready to hand to a video player.
  #
  # The Manifest is the read-side counterpart to ApplicationVideo. A
  # profile class hands one to its caller via `profile.manifest(path)`,
  # but Manifest can also be used directly with any bucket.
  #
  # Example:
  #
  #   manifest = CourseVideo.manifest("phlex/forms/overview")
  #   manifest.master_playlist  # => M3u8::Playlist with rewritten URIs
  #   manifest.poster_url       # => pre-signed URL string
  #
  # `master_playlist` rewrites variant URIs from ffmpeg's flat
  # `0/index.m3u8` form to a controller-routable `<path>/0.m3u8` shape
  # so the host app's controller can serve each variant by name.
  class Manifest
    DEFAULT_POSTER  = "poster"
    MASTER_PLAYLIST = "index.m3u8"
    VARIANT_PLAYLIST = "index.m3u8"

    attr_reader :bucket, :path, :expires_in, :segment_duration

    # bucket::          Aws::S3::Bucket
    # path::            S3 key prefix where the bundle lives
    # expires_in::      pre-signed URL TTL in seconds
    # segment_duration:: HLS segment length, drives Variant#duration math
    # variant_uri::     callable taking (path:, variant_index:) and
    #                   returning the URI string to put in the master
    #                   playlist for that variant. Default produces
    #                   `<basename(path)>/<index>.m3u8`, which matches a
    #                   `/videos/*path/:id/:variant` Rails route shape.
    #                   Override it to fit a different URL scheme.
    def initialize(bucket:, path:, expires_in:, segment_duration: 4, variant_uri: nil)
      @bucket           = bucket
      @path             = path
      @expires_in       = Integer(expires_in)
      @segment_duration = Integer(segment_duration)
      @variant_uri      = variant_uri || DEFAULT_VARIANT_URI
    end

    DEFAULT_VARIANT_URI = ->(path:, variant_index:) {
      "#{::File.basename(path)}/#{variant_index}.m3u8"
    }

    # Pre-signed URL for a poster image. With no argument, returns
    # `<path>/poster.jpg` (back-compat with the legacy `HLS::Poster`
    # filename). With a name, returns `<path>/<name>.jpg`.
    def poster_url(name = DEFAULT_POSTER)
      presigned_url("#{name}.jpg")
    end

    # Master playlist with variant URIs rewritten from ffmpeg's
    # `<index>/index.m3u8` form to whatever the configured `variant_uri`
    # callable returns. The default produces `<id>/<index>.m3u8` where
    # `<id>` is the last segment of the manifest's path — relative to
    # the master playlist's URL, so a player fetching
    # `/videos/<path>/<id>.m3u8` resolves the variant URI to
    # `/videos/<path>/<id>/<index>.m3u8`.
    #
    # Returns a fresh M3u8::Playlist on each call (does not mutate the
    # cached raw playlist).
    def master_playlist
      list = M3u8::Playlist.new
      list.items = raw_master_playlist.items.map do |item|
        rewritten = item.clone
        rewritten.uri = @variant_uri.call(
          path: path,
          variant_index: ::File.dirname(item.uri)
        )
        rewritten
      end
      list
    end

    # All variants discovered in the master playlist, indexed by
    # ffmpeg's variant path (`"0"`, `"1"`, ...).
    def variants
      @variants ||= raw_master_playlist.items.map do |item|
        variant_path = ::File.dirname(item.uri)
        variant_playlist = read_playlist(variant_path, VARIANT_PLAYLIST)
        Variant.new(manifest: self, variant_path: variant_path, items: variant_playlist.items)
      end
    end

    # Look up a variant by ffmpeg's path identifier ("0", "1", ...).
    def variant(variant_path)
      variants.find { |v| v.variant_path == variant_path }
    end

    # Pre-signs an arbitrary key under this manifest's path.
    def presigned_url(*parts, expires_in: self.expires_in)
      object(*parts).presigned_url(:get, expires_in: Integer(expires_in))
    end

    private

    def object(*parts)
      bucket.object(::File.join(path, *parts))
    end

    def read_object(*parts)
      object(*parts).get.body.read
    end

    def read_playlist(*parts)
      M3u8::Reader.new.read(read_object(*parts))
    end

    # The raw, untouched master playlist as ffmpeg wrote it. Kept private
    # because callers should always go through `master_playlist`, which
    # rewrites variant URIs. Memoized so repeated reads (poster_url +
    # master_playlist + variants in one request) only pay one S3 GET.
    def raw_master_playlist
      @raw_master_playlist ||= read_playlist(MASTER_PLAYLIST)
    end

    # A single rendition variant — its ordered list of segments and the
    # ability to slice a duration window for previews.
    class Variant
      attr_reader :manifest, :variant_path, :items

      def initialize(manifest:, variant_path:, items:)
        @manifest = manifest
        @variant_path = variant_path
        @items = items
      end

      # Duration in seconds. Approximate — uses segment_duration as a
      # uniform per-segment value, which matches how ffmpeg writes VOD
      # bundles. The last segment may be slightly shorter.
      def duration
        items.count * manifest.segment_duration
      end

      # Slice a duration window. The range is in seconds. Inclusive ranges
      # round down, exclusive ranges round up. Useful for preview windows
      # (e.g. `variant[0...30]` for a 30-second teaser).
      def [](range)
        raise ArgumentError, "Only Range objects are supported" unless range.is_a?(Range)

        segment_count =
          if range.exclude_end?
            (range.end.to_f / manifest.segment_duration).ceil
          else
            (range.end.to_f / manifest.segment_duration).floor
          end

        Variant.new(manifest: manifest, variant_path: variant_path, items: items.take(segment_count))
      end

      # The variant playlist with each segment rewritten to a pre-signed
      # URL. Returns a fresh M3u8::Playlist; does not mutate `items`.
      def playlist
        list = M3u8::Playlist.new
        list.items = items.map do |item|
          signed = item.clone
          signed.segment = manifest.presigned_url(variant_path, item.segment)
          signed
        end
        list
      end
    end
  end
end
