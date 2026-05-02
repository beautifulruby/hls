# 01 — Profile DSL

## Goal

A Rails app declares video profiles as classes in `app/videos/`, and each
class fully describes its renditions, codec, and storage. The profile class is
the unit — encode, upload, and (later) read all hang off it.

```ruby
# app/videos/application_video.rb
class ApplicationVideo < HLS::ApplicationVideo
  bucket ENV.fetch("VIDEO_S3_BUCKET_NAME")
  signing_ttl 1.hour
  segment_duration 4
end

# app/videos/course_video.rb
class CourseVideo < ApplicationVideo
  rendition :full,   scale: 1.0
  rendition :medium, scale: 0.5
  rendition :small,  scale: 0.25
end

# app/videos/screencast_video.rb
class ScreencastVideo < ApplicationVideo
  bits_per_pixel :screencast
  rendition width: 1920, height: 1080, bitrate: 2_500
  rendition width: 1280, height: 720,  bitrate: 1_500
end
```

## Preconditions

- Existing `HLS::Video::Base`, `HLS::Video::Scalable`, `HLS::Video::VTechWatch`
  classes in `lib/hls.rb` (already there).
- Existing `HLS::Poster` (already there).

## Work

### 1. Extract `HLS::ApplicationVideo` base class

In `lib/hls/application_video.rb`:

- Class-level DSL: `bucket`, `signing_ttl`, `segment_duration`,
  `audio_codec`, `audio_bitrate`, `video_codec`, `bits_per_pixel`.
- Class-level `rendition(...)` accumulator. Two forms:
  - Explicit: `rendition width:, height:, bitrate:`
  - Scaled: `rendition :name, scale: 1.0` (computed from input dimensions
    using the existing `Scalable#estimated_bitrate` math).
- DSL values are inherited and overridable (subclasses see parent renditions
  unless they redeclare).
- `.new(input:, output:)` constructs an instance bound to one input.
- `#process` runs the full pipeline (encode + poster + upload, wired in
  step 02).

### 2. Migrate existing classes

- `HLS::Video::Scalable` → keep as a strategy helper (`Scalable.renditions_for(input)`)
  used by profile classes that want auto-scaling. Or fold it into a
  `scaled_renditions n: 3` DSL macro on `ApplicationVideo`.
- `HLS::Video::VTechWatch` → delete (it's a dev-loop hack; replace with a
  `FastVideo` example profile in tests/fixtures).

### 3. Railtie

In `lib/hls/railtie.rb`:

- Register `app/videos` as an autoload + eager-load path.
- Expose `Rails.application.config.hls` for app-wide defaults
  (default bucket, default signing TTL, default codec).
- Wire `Rails.application.config.hls.s3_client` so the gem uses the host
  app's `Aws::S3::Resource` configuration (matches `Video::Tigris` setup
  in `server/app/models/video.rb:4-9`).

### 4. Backwards-compatible shim

Keep `HLS::Video::Base#command` working unchanged so step 02 doesn't have to
touch ffmpeg arg construction. The DSL classes should compose down to the
same command array Base produces today.

## Acceptance

- [x] `HLS::ApplicationVideo` exists; `bucket`, `signing_ttl`,
      `segment_duration`, `rendition` work as documented above.
- [x] A subclass with three `rendition :name, scale: ...` declarations
      produces a `command` array byte-identical to today's
      `HLS::Video::Scalable.new(input:, output:)` for a fixture input.
- [x] A subclass with explicit `rendition width:, height:, bitrate:`
      produces the expected ffmpeg command for a fixed-size encode.
- [x] Subclass inheritance works: a child class inherits parent's `bucket`
      and `signing_ttl` unless it overrides.
- [x] Railtie autoloads `app/videos/*.rb` in a Rails dummy app under
      `spec/dummy` (or equivalent); `CourseVideo` resolves via constantize.
- [x] `HLS::Video::VTechWatch` is gone; nothing in `examples/` or tests
      references it.
- [x] Unit tests cover the DSL accumulator, inheritance, and the
      Scalable-equivalence golden test.

## Open questions

- Do we want a `scaled_renditions count: 3` macro, or stay explicit per
  rendition? Probably explicit — it's three lines and more readable.
- Should `bucket` accept an `Aws::S3::Bucket` directly, a name string, or
  both? Probably both, with a string being looked up via the configured
  S3 client.
