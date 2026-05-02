# frozen_string_literal: true

require "digest"
require "stringio"

module HLS
  # The storage protocol the gem expects from a "bucket" object. Any
  # value passed to `bucket` on a profile (or returned by your custom
  # resource) must implement this interface.
  #
  # The default implementation is `Aws::S3::Bucket`, which already
  # conforms — no wrapper needed for ordinary S3 / Tigris use.
  #
  # # Protocol
  #
  # ## Bucket
  #
  #   bucket.object(key) -> Object
  #
  # Returns an Object handle for the given key. Should not perform any
  # network I/O.
  #
  # ## Object
  #
  #   object.get -> something with a `.body` that is an IO/StringIO
  #
  # Reads the full object body from the backend. Used by Manifest when
  # fetching playlists.
  #
  #   object.put(body:, content_type:, cache_control:) -> response
  #
  # Writes the object. The response must respond to `.etag`. Used by
  # Uploader.
  #
  #   object.presigned_url(:get, expires_in:) -> URL string
  #
  # Returns a time-limited URL clients can use to fetch the object
  # directly. Used by Manifest for variant segment URLs and poster URLs.
  #
  # # In-memory adapter
  #
  # `HLS::Storage::Memory` is a no-network bucket implementation useful
  # for tests and local previews. It satisfies the protocol above and
  # delivers signed URLs as plain `memory://` strings — they aren't
  # browser-loadable, but they round-trip cleanly through a Manifest so
  # you can assert on them in specs.
  module Storage
    # In-memory bucket for tests. Backed by a hash. Not thread-safe; if
    # you parallelize through this adapter, wrap it yourself.
    class Memory
      def self.build(name: "memory", objects: {})
        bucket = new(name: name)
        objects.each { |key, body| bucket.object(key).put(body: body) }
        bucket
      end

      attr_reader :name

      def initialize(name:)
        @name = name
        @store = {}
      end

      def object(key)
        Object.new(store: @store, key: key)
      end

      def keys
        @store.keys
      end

      class Object
        attr_reader :key

        def initialize(store:, key:)
          @store = store
          @key = key
        end

        def get
          entry = @store.fetch(@key) { raise KeyError, "no object at #{@key}" }
          Response.new(body: StringIO.new(entry[:body].to_s), content_type: entry[:content_type])
        end

        def put(body:, content_type: "application/octet-stream", cache_control: nil)
          body_str = body.respond_to?(:read) ? body.read : body.to_s
          @store[@key] = {
            body: body_str,
            content_type: content_type,
            cache_control: cache_control
          }
          PutResponse.new(etag: %("#{Digest::MD5.hexdigest(body_str)}"))
        end

        def presigned_url(_verb = :get, expires_in: 3600, **_)
          "memory://#{@key}?expires_in=#{expires_in}"
        end
      end

      Response = Struct.new(:body, :content_type, keyword_init: true)
      PutResponse = Struct.new(:etag, keyword_init: true)
    end
  end
end
