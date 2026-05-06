# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-06

A near-total rewrite of the configuration surface and a much more
production-ready encode/upload pipeline. The DSL is smaller, the
storage layer is pluggable, the encode is idempotent against config
changes, and the read side has cache, retries, and instrumentation
hooks. Three Rails generators scaffold the whole thing in one
command.

### Highlights

- New `HLS::Storage` adapter pattern (`S3` is the default; `Memory`
  ships for tests). `bucket_name` and `signing_ttl` are now grouped
  on the storage object instead of split across the profile class.
- `HLS::Cache` groups the read-side cache backend with its TTL — same
  shape as Storage.
- Encode idempotency now respects profile config: bumping
  `audio_bitrate` or adding a rendition triggers a re-encode instead
  of being silently skipped.
- `HLS::EncodeJob` ActiveJob wrapper with sane retry policy.
- `bin/rails g hls:install` and `bin/rails g hls:video NAME`
  generators.
- ActiveSupport::Notifications events for every pipeline stage, opt-in
  ffmpeg timeout, parallel/retrying uploader, advisory file lock, and
  full-bundle verification before recording state.

### Migration from 0.1.0

Two patterns to update:

1. **Config moves onto the profile class via plain Ruby.** The
   `Rails.application.config.hls` bag and the
   `:hls_application_video` load hook are gone. Initializers shrink
   to one line:

   ```ruby
   # config/initializers/hls.rb
   HLS.s3_resource = Aws::S3::Resource.new(...)
   ```

   Per-profile bucket and signing TTL move onto the profile class:

   ```ruby
   # app/videos/application_video.rb
   class ApplicationVideo < HLS::ApplicationVideo
     def self.storage = HLS::Storage::S3.new(
       bucket_name: ENV.fetch("VIDEO_S3_BUCKET_NAME"),
       signing_ttl: 1.hour
     )
   end
   ```

2. **`HLS::Manifest.new` and `HLS::Uploader.new` take `storage:`** —
   not `bucket:` and not `expires_in:`. `Manifest` reads its TTL from
   `storage.signing_ttl`. The read-side cache is now a single
   `cache:` argument:

   ```ruby
   def self.cache = HLS::Cache.new(backend: Rails.cache, ttl: 5.minutes)
   ```

**One-time re-encode on first deploy.** `config_digest` (the new hash
of profile config that gates encode skipping) now sorts payload keys
before SHA256, so previously-recorded digests no longer match. The
next `process` run re-encodes every video once; subsequent runs are
no-ops as before.

### Breaking

- `HLS::ApplicationVideo`'s polymorphic `bucket` setting and the
  matching `signing_ttl` / `resolve_bucket` are gone. Configure via
  `def self.storage = HLS::Storage::S3.new(...)`.
- `manifest_cache` + `manifest_cache_ttl` settings are gone. Configure
  via `def self.cache = HLS::Cache.new(backend:, ttl:)`.
- `HLS::Manifest.new` no longer takes `expires_in:` or `cache_ttl:`.
- The Railtie no longer registers `Rails.application.config.hls` or
  fires the `:hls_application_video` load hook.
- `config_digest` serialized form changed (sorted keys); see above for
  the one-time re-encode.

### Added

- **Storage adapter pattern.** `HLS::Storage::S3` (default) and
  `HLS::Storage::Memory` (test/dev). Custom adapters need only
  `signing_ttl` + `object(key)` returning something that responds to
  `get`, `put`, `presigned_url`.
- **`HLS::Cache`** wrapping any `Rails.cache`-shaped backend
  (`fetch(key, &block)`) with a configured TTL.
- **Config-aware encode idempotency.** State sidecar records a
  `config_digest` alongside `input_digest`. Encode re-runs when
  *either* the input bytes or the encode-affecting profile config
  changes. Settings that don't affect output bytes (`storage`,
  `cache`, `ffmpeg_timeout`, `variant_uri`) are excluded from the
  digest.
- **Rails generators.** `bin/rails g hls:install` scaffolds the
  initializer + base profile. `bin/rails g hls:video NAME` writes a
  per-content-type profile with a sensible 3-rendition ladder and a
  hero poster.
- **`HLS::EncodeJob` retry policy.** `discard_on HLS::Lock::Busy`
  (another worker is doing it) and `discard_on HLS::State::CorruptError`
  (poison message — operator intervention required). Other errors
  follow the host app's default retry policy.
- **ActiveSupport::Notifications events.** `encode.hls`, `poster.hls`,
  `verify.hls`, `upload_object.hls`, `upload_retry.hls`, `process.hls`
  — published when AS is loaded; pure-Ruby usage is a no-op. See
  README for payload keys.
- **Configurable `ffmpeg_timeout`** (in seconds). Stuck ffmpeg gets
  SIGTERM then SIGKILL after a grace period. `nil` default preserves
  prior behavior.
- **Encode bundle verification.** `verify_encode!` walks the just-
  encoded output and asserts master + variants + segments + posters
  all exist and are non-empty *before* recording state and starting
  the upload pass. A failed verify doesn't claim success.
- **ffmpeg stderr capture.** Failure errors include the tail of
  ffmpeg's stderr — diagnosable without re-running with verbose
  logging.
- **Input validation.** `HLS::Input#validate!` raises early on
  audio-only or malformed input. The encode pipeline calls it before
  invoking ffmpeg.
- **Advisory file lock** at `<output>/.hls-lock`. `process` acquires
  it before encoding; a competing worker for the same output dir gets
  `HLS::Lock::Busy` immediately rather than corrupting state.
- **Threaded uploader with retries.** Bounded-concurrency parallel
  PUTs (default 4 workers). Transient errors (network, 503,
  RequestTimeout, SlowDown, InternalError) retry with exponential
  backoff up to `max_retries`. Permanent errors (NoSuchBucket, 403)
  fail fast.
- **Pluggable read-side manifest cache.** `Manifest` reads playlists
  through the configured `cache` object when present, cutting S3 GETs
  for hot videos.
- **`resolve_variants_under` RSpec matcher** for catching the
  variant-URI-doubling bug class by simulating RFC 3986 resolution
  against the master URL.

### Changed

- **GOP size scales with `segment_duration`** (`framerate ×
  segment_duration`) instead of a hardcoded 180. Each HLS segment
  starts on a keyframe regardless of the configured segment length —
  fixes seek stalls on non-default `segment_duration`.
- **Variant URIs are generated by an overridable
  `variant_uri(path:, variant_index:)` class method.** Default returns
  `<basename(path)>/<variant_index>.m3u8`, which resolves cleanly
  under a `/videos/*path/:id.m3u8` route shape.
- **Cache-Control on uploaded `.m3u8` files** relaxed from `no-cache`
  to `public, max-age=300` so a CDN can edge-cache playlists between
  re-encodes.
- **ffprobe / ffmpeg subprocess calls** moved from backticks / `system`
  to `Open3.capture3` throughout for safer argument handling and
  stderr capture.

### Removed

- Dropped unused `parallel` and `bigdecimal` gem dependencies. The
  uploader does its own bounded threading via `Queue` + `Thread.new`;
  nothing in `lib/` touches BigDecimal.

## [0.1.0]

- Initial release.
