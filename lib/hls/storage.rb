# frozen_string_literal: true

require "digest"
require "stringio"

module HLS
  # The storage protocol the gem talks through to put/get objects and
  # produce signed URLs. Profile classes attach an instance of one of
  # these to themselves via `storage`.
  #
  # # Protocol
  #
  #   storage.signing_ttl     -> Integer (default TTL for presigned URLs)
  #   storage.object(key)     -> Object  (no I/O)
  #
  #   object.get              -> response with .body (IO-like)
  #   object.put(body:, content_type:, cache_control:) -> response with .etag
  #   object.presigned_url(:get, expires_in:) -> URL string
  #
  # # Built-in adapters
  #
  # - `HLS::Storage::S3`     — default. Wraps an `Aws::S3::Bucket`.
  # - `HLS::Storage::Memory` — in-process bucket for tests. Signed URLs
  #   are non-browser `memory://` strings but round-trip through a
  #   Manifest so you can assert on them.
  module Storage
    # Default storage backend: an Aws::S3::Bucket plus a signing TTL.
    # Constructed with either a bucket name (resolved through
    # HLS.s3_resource at first use) or a pre-built Aws::S3::Bucket
    # (useful in tests or when the host already built one).
    #
    #   HLS::Storage::S3.new(bucket_name: "videos", signing_ttl: 1.hour)
    #   HLS::Storage::S3.new(bucket: my_aws_bucket, signing_ttl: 60)
    class S3
      DEFAULT_SIGNING_TTL = 3600

      attr_accessor :signing_ttl
      attr_reader :bucket_name

      def initialize(bucket_name: nil, bucket: nil, s3_resource: nil, signing_ttl: DEFAULT_SIGNING_TTL)
        @bucket_name = bucket_name
        @bucket = bucket
        @s3_resource = s3_resource
        @signing_ttl = signing_ttl
      end

      def object(key)
        bucket.object(key)
      end

      # The underlying Aws::S3::Bucket. Resolved lazily so a profile
      # can declare `def self.storage = HLS::Storage::S3.new(bucket_name:
      # ENV.fetch("..."))` without forcing an SDK lookup at class-load
      # time.
      def bucket
        @bucket ||= begin
          if bucket_name.to_s.empty?
            raise ArgumentError,
              "HLS::Storage::S3 needs either a bucket_name or a pre-built bucket"
          end
          (@s3_resource || HLS.s3_resource).bucket(bucket_name)
        end
      end
    end

    # In-memory bucket for tests. Backed by a hash protected by a
    # single mutex — concurrent puts and gets across threads are safe.
    class Memory
      DEFAULT_SIGNING_TTL = 3600

      def self.build(name: "memory", signing_ttl: DEFAULT_SIGNING_TTL, objects: {})
        bucket = new(name: name, signing_ttl: signing_ttl)
        objects.each { |key, body| bucket.object(key).put(body: body) }
        bucket
      end

      attr_reader :name
      attr_accessor :signing_ttl

      def initialize(name:, signing_ttl: DEFAULT_SIGNING_TTL)
        @name = name
        @signing_ttl = signing_ttl
        @store = {}
        @mutex = Mutex.new
      end

      def object(key)
        Object.new(store: @store, mutex: @mutex, key: key)
      end

      def keys
        @mutex.synchronize { @store.keys }
      end

      class Object
        attr_reader :key

        def initialize(store:, mutex:, key:)
          @store = store
          @mutex = mutex
          @key = key
        end

        def get
          entry = @mutex.synchronize { @store[@key] }
          raise KeyError, "no object at #{@key}" if entry.nil?
          Response.new(body: StringIO.new(entry[:body].to_s), content_type: entry[:content_type])
        end

        def put(body:, content_type: "application/octet-stream", cache_control: nil)
          body_str = body.respond_to?(:read) ? body.read : body.to_s
          @mutex.synchronize do
            @store[@key] = {
              body: body_str,
              content_type: content_type,
              cache_control: cache_control
            }
          end
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
