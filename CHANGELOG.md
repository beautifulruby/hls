# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-06

### Changed (breaking)

- **`config_digest` now sorts hash keys before SHA256ing the payload.**
  The serialized form is stable across Ruby versions and hash insertion
  order. *One-time effect on existing deployments:* the next `process`
  run will re-encode every video once, since previously-recorded
  digests no longer match the new representation. Subsequent runs are
  no-ops as before.

- **`HLS::Cache` groups the playlist cache backend with its TTL.** The
  separate `manifest_cache` + `manifest_cache_ttl` class settings (and
  the `cache_ttl:` kwarg on `HLS::Manifest.new`) are gone. Configure
  one object on the profile:

      class ApplicationVideo < HLS::ApplicationVideo
        def self.cache = HLS::Cache.new(backend: Rails.cache, ttl: 5.minutes)
      end

  `HLS::Manifest` accepts an `HLS::Cache` or any object responding to
  `fetch(key, &block)` (raw `Rails.cache` still works — it just uses
  the cache's own default TTL).

- **`HLS::Storage::S3` is now the default storage adapter** and owns
  `bucket_name` + `signing_ttl`. The polymorphic `bucket` setting on
  `HLS::ApplicationVideo` (and the matching `signing_ttl` setting and
  `resolve_bucket` method) are removed. Configure profiles like:

      class ApplicationVideo < HLS::ApplicationVideo
        def self.storage = HLS::Storage::S3.new(
          bucket_name: ENV.fetch("VIDEO_S3_BUCKET_NAME"),
          signing_ttl: 1.hour
        )
      end

  `HLS::Manifest` and `HLS::Uploader` now take `storage:` instead of
  `bucket:` (and `Manifest` no longer takes `expires_in:` — it reads
  it from `storage.signing_ttl`).

- **The Railtie no longer fires the `:hls_application_video` load
  hook**, no longer registers a `Rails.application.config.hls` config
  bag, and no longer copies values onto profile classes via a
  separate initializer. Settings live on the profile classes directly
  (Zeitwerk reloads handle dev-mode freshness). Initializers shrink to
  one line: `HLS.s3_resource = Aws::S3::Resource.new(...)`.

### Added

- **`HLS::EncodeJob` retry policy.** `discard_on` for `HLS::Lock::Busy`
  (another worker is doing it) and `HLS::State::CorruptError` (operator
  intervention required) — both are poison messages that ActiveJob's
  default retry-everything-five-times behavior wastes work on. Other
  errors continue to follow the host app's default retry policy.

### Removed

- **Dropped `parallel` and `bigdecimal` gem dependencies.** Neither was
  used in `lib/`. The Uploader does its own bounded threading via
  `Queue` + `Thread.new`, and nothing in the gem touches BigDecimal.

### Added

- **Config-aware encode idempotency.** The state sidecar now records
  a `config_digest` alongside `input_digest` — a SHA256 of the
  encode-affecting profile config (renditions, posters, codecs,
  bitrates, segment_duration, bits_per_pixel). `process` re-runs
  ffmpeg when *either* the input bytes or the profile config has
  changed since the last successful encode. Previously, bumping
  `audio_bitrate` or adding a rendition was a silent no-op on
  re-run. Settings that don't affect output bytes (`storage`,
  `cache`, `ffmpeg_timeout`, `variant_uri`) are excluded.
- **Rails generators.** `bin/rails g hls:install` scaffolds
  `config/initializers/hls.rb` and `app/videos/application_video.rb`.
  `bin/rails g hls:video NAME` writes a per-content-type profile under
  `app/videos/` with a sensible default ladder, an active hero poster,
  and commented hints for the common per-profile overrides.

- **ffmpeg stderr capture.** When ffmpeg fails, the tail of its stderr
  is included in `HLS::Error` so failures are diagnosable without
  re-running with verbose logging.
- **Input validation.** `HLS::Input#validate!` raises early when the
  input has no video stream (audio-only files, malformed media), and
  `#video?` exposes the same predicate. The encode pipeline calls
  `validate!` before invoking ffmpeg.
- **Lock file in output dir.** `HLS::Lock` provides advisory file
  locking via `flock`. `process` acquires it before encoding/uploading;
  a second concurrent worker for the same output dir gets
  `HLS::Lock::Busy` instead of corrupting state.
- **Encode bundle verification.** `verify_encode!` walks the just-
  encoded output, asserting the master + variants + segments + posters
  all exist and are non-empty, before recording state and uploading.
- **ActiveSupport::Notifications hooks.** Events `encode.hls`,
  `poster.hls`, `verify.hls`, `upload_object.hls`, `upload_retry.hls`,
  and `process.hls` published when AS is loaded; pure-Ruby usage is a
  no-op. See README for payload keys.
- **Configurable ffmpeg timeout.** `ffmpeg_timeout` class setting (in
  seconds) terminates a stuck ffmpeg with SIGTERM then SIGKILL. `nil`
  default preserves prior behavior.
- **S3 retry with backoff.** Uploader retries transient failures
  (network errors, 503, RequestTimeout, SlowDown, InternalError) up to
  `max_retries` times with exponential backoff. Permanent errors
  (NoSuchBucket, 403) fail fast.
- **Threaded uploader.** Bounded-concurrency parallel uploads via a
  worker pool. Default `concurrency: 4`. Set to `1` for serial.
- **GOP scales with segment_duration.** Keyframe interval is now
  `framerate × segment_duration` instead of a hardcoded 180. Each HLS
  segment starts on a keyframe regardless of the configured segment
  length, fixing seek stalls on non-default `segment_duration`.
- **Storage adapter pattern.** `bucket` accepts any object responding
  to `object(key)` that yields a duck-typed object with `get`, `put`,
  and `presigned_url`. `HLS::Storage::Memory` ships as a no-network
  adapter for tests. Documented MinIO setup in README.
- **Pluggable Manifest cache.** Read-side Manifest accepts a `cache:`
  object (an `HLS::Cache` wrapping a `Rails.cache`-shaped backend, or
  any object responding to `fetch(key, &block)`) to cut S3 GETs for
  hot videos.
- **`resolve_variants_under` RSpec matcher.** Public test helper that
  catches the variant-URI-doubling bug class by simulating RFC 3986
  resolution against the master URL.

### Changed

- Variant URIs in the master playlist are now generated by an
  overridable `variant_uri(path:, variant_index:)` class method.
  Default returns `<basename(path)>/<variant_index>.m3u8`, which
  resolves cleanly under a `/videos/*path/:id.m3u8` route shape.
- Cache-Control on uploaded `.m3u8` files relaxed from `no-cache` to
  `public, max-age=300` so a CDN can edge-cache playlists between
  re-encodes.
- ffprobe / ffmpeg subprocess calls switched from backticks / `system`
  to `Open3.capture3` for safer argument handling and stderr capture.

## [0.1.0]

- Initial release.
