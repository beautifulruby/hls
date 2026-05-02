# frozen_string_literal: true

require "digest"
require "pathname"

require_relative "instrumentation"
require_relative "lock"

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

    # Default retries on top of the AWS SDK's own retry behavior. Bumped
    # to absorb transient network errors during long, multi-object
    # uploads where the SDK's retry budget per call has been exhausted.
    DEFAULT_MAX_RETRIES = 3
    DEFAULT_INITIAL_BACKOFF = 0.5

    # Parallel upload workers. The SDK is thread-safe, S3 is throughput-
    # bound on typical connections, and a 3-rendition bundle is dozens
    # of small segments — overlapping their PUTs cuts wall-clock time
    # significantly. 4 workers is a good default for home/office links;
    # bump higher on a beefy server with a fat pipe.
    DEFAULT_CONCURRENCY = 4

    # Errors classed as transient and worth retrying. We deliberately
    # don't include the broad Aws::Errors::ServiceError parent — a 403
    # or NoSuchBucket should fail fast, not retry.
    TRANSIENT_ERRORS = [
      Seahorse::Client::NetworkingError,
      Aws::S3::Errors::RequestTimeout,
      Aws::S3::Errors::ServiceUnavailable,
      Aws::S3::Errors::SlowDown,
      Aws::S3::Errors::InternalError
    ].freeze

    attr_reader :bucket, :output, :key_prefix, :state,
                :max_retries, :initial_backoff, :concurrency

    def initialize(bucket:, output:, key_prefix:, state:,
                   max_retries: DEFAULT_MAX_RETRIES,
                   initial_backoff: DEFAULT_INITIAL_BACKOFF,
                   concurrency: DEFAULT_CONCURRENCY)
      @bucket = bucket
      @output = Pathname.new(output)
      @key_prefix = key_prefix.to_s.sub(%r{\A/}, "").sub(%r{/\z}, "")
      @state = state
      @max_retries = max_retries
      @initial_backoff = initial_backoff
      @concurrency = [concurrency.to_i, 1].max
      @state_mutex = Mutex.new
    end

    # Upload everything under the output directory that hasn't been
    # uploaded yet. Returns a hash with :uploaded and :skipped counts.
    def perform
      pending = uploadable_files.filter_map do |file|
        relative_key = relative_key_for(file)
        digest = md5_of(file)
        next nil if @state_mutex.synchronize {
          state.uploaded?(relative_key: relative_key, digest: digest)
        }
        [file, relative_key, digest]
      end

      skipped = uploadable_files.size - pending.size
      uploaded = upload_in_parallel(pending)

      { uploaded: uploaded, skipped: skipped }
    end

    private

    def upload_in_parallel(pending)
      return 0 if pending.empty?

      queue = Queue.new
      pending.each { |item| queue << item }
      concurrency.times { queue << :stop }

      uploaded = 0
      uploaded_mutex = Mutex.new
      first_error = nil
      error_mutex = Mutex.new

      workers = Array.new([concurrency, pending.size].min) do
        Thread.new do
          loop do
            item = queue.pop
            break if item == :stop
            break if error_mutex.synchronize { first_error }
            file, relative_key, digest = item

            begin
              response = upload(file, relative_key: relative_key)
              @state_mutex.synchronize do
                state.record_upload(relative_key: relative_key, digest: digest, etag: response.etag)
                state.save
              end
              uploaded_mutex.synchronize { uploaded += 1 }
            rescue => e
              error_mutex.synchronize { first_error ||= e }
              break
            end
          end
        end
      end

      workers.each(&:join)
      raise first_error if first_error
      uploaded
    end

    def upload(file, relative_key:)
      key = key_for(relative_key)
      ct = content_type_for(file)
      response = nil
      HLS::Instrumentation.instrument(:upload_object,
        key: key, bytes: file.size, content_type: ct
      ) do
        with_retries(key: key) do
          object = bucket.object(key)
          response = object.put(
            body: file.open("rb"),
            content_type: ct,
            cache_control: cache_control_for(file)
          )
        end
      end
      response
    end

    # Retries a transient error a bounded number of times with
    # exponential backoff. Per-attempt instrumentation lets the host
    # app see retries happening (and decide whether the budget is too
    # generous).
    def with_retries(key:)
      attempt = 0
      backoff = initial_backoff
      begin
        yield
      rescue *TRANSIENT_ERRORS => e
        attempt += 1
        raise if attempt > max_retries
        HLS::Instrumentation.instrument(:upload_retry,
          key: key, attempt: attempt, error: e.class.name, message: e.message
        ) {}
        sleep backoff
        backoff *= 2
        retry
      end
    end

    def uploadable_files
      output.glob("**/*")
        .select { |p| p.file? }
        .reject { |p| skip?(p) }
        .sort
    end

    # Skip the state sidecar and lock file (we never upload them) plus
    # any junk dotfiles macOS / editors leave behind (.DS_Store, ._*).
    def skip?(path)
      basename = path.basename.to_s
      basename == State::FILENAME ||
        basename == Lock::FILENAME ||
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
