# HLS

If your videos already live in your S3 bucket, this gem is the cheaper
alternative to a second vendor.

For the [Phlex on Rails course](https://beautifulruby.com/phlex) I
needed multi-bitrate streaming for a few hundred lectures. Mux would
have worked, but it meant a second bill, a second SDK, a second
dashboard, a second place credentials rotate, a second on-call channel
when something breaks — for content that already sits next to my other
course assets in Tigris. So instead this gem wraps `ffmpeg` to encode
the source into [HLS](https://en.wikipedia.org/wiki/HTTP_Live_Streaming)
(multi-bitrate, segmented for adaptive streaming), generates
pre-signed URLs for every segment, and gives you a small Rails seam to
serve them — all without leaving the bucket and credentials you
already manage.

That's the whole pitch. No hosted player, no analytics service, no
separate billing. Just `ffmpeg` plumbing and a manifest helper, sized
to fit a course site or any content-heavy app where "add another SaaS"
is the wrong answer.

## What you get

- **ffmpeg multi-rendition encoding with sane defaults.** Codec
  auto-selection per host (videotoolbox on macOS, NVENC/QSV on Linux
  GPUs, libx264 fallback), GOP aligned to segment boundaries so seeks
  don't stall, and a bitrate ladder scaled from the source dimensions.
- **Pre-signed URLs baked into the playlists you serve.** The player
  fetches segments directly from the bucket; your app server never
  proxies bytes.
- **Idempotent re-runs.** A re-encode is a no-op unless the input
  bytes or the profile config actually changed.
- **Rails integration.** Autoloaded profile classes under
  `app/videos/`, an `HLS::EncodeJob` ActiveJob wrapper, and
  `bin/rails g hls:install` / `hls:video` generators that scaffold
  the whole thing.

## What it's not

A replacement for Mux, Bitmovin, or any other hosted video service —
those give you a managed CDN, viewer analytics, and a player UI in
one bundle. This gives you the encoded files in your own bucket and
the URLs to serve them. Bring your own player (`hls.js`, native iOS
Safari) and your own CDN if you want one in front of the bucket.

## A note on construction

I wrote most of this with an LLM in June 2025 — early ChatGPT plus
the first generation of Claude agents — and have continued iterating
the same way since. Wrapping `ffmpeg` flags and generating pre-signed
URLs is exactly the kind of mechanical glue where that helps. The
codebase is small (`lib/hls/` is under 2k lines) and worth reading if
you want to verify what it does before you depend on it.

## Requirements

- Ruby 3.1+
- `ffmpeg` and `ffprobe` on the PATH (Homebrew, apt, or your distro
  equivalent)
- An S3-compatible bucket (Tigris, Cloudflare R2, AWS S3, MinIO, etc.)

## Support

Consider [buying a video course from Beautiful Ruby](https://beautifulruby.com) and learn a thing or two to keep the machine going that originally built this gem.

[![](https://immutable.terminalwire.com/NgTt6nzO1aEnExV8j6ODuKt2iZpY74ZF8ecpUSCp4A0tXA0ErpJIS4cdMX0tQQKOWwZSl65jWnpzpgCLJThhhWtZJGr42XKt7WIi.png)](https://beautifulruby.com/phlex)

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add hls
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install hls
```

In a Rails app, scaffold the initial config + base profile with:

```bash
bin/rails g hls:install
```

This writes `config/initializers/hls.rb` (with env-var-driven bucket /
S3 config) and `app/videos/application_video.rb` (the base class your
profiles inherit from). Then generate per-content-type profiles:

```bash
bin/rails g hls:video Course
# => app/videos/course_video.rb
```

The generated profile has a sensible 3-rendition ladder, a hero
poster, and inline comments for the common knobs. Edit to tune.

## Usage

### Declare a profile

In a Rails app, `app/videos/*.rb` is autoloaded and inherits app-wide
defaults from `config/initializers/hls.rb`:

```ruby
# config/initializers/hls.rb
require "aws-sdk-s3"

HLS.s3_resource = Aws::S3::Resource.new(
  access_key_id:     ENV.fetch("VIDEO_AWS_ACCESS_KEY_ID"),
  secret_access_key: ENV.fetch("VIDEO_AWS_SECRET_ACCESS_KEY"),
  endpoint:          ENV.fetch("VIDEO_S3_ENDPOINT_URL"),
  region:            "auto"
)

# app/videos/application_video.rb — bucket + signing TTL live on the
# storage adapter, configured here so every subclass under app/videos
# inherits them. Override `def self.storage` on a subclass to point
# at a different bucket.
class ApplicationVideo < HLS::ApplicationVideo
  def self.storage = HLS::Storage::S3.new(
    bucket_name: ENV.fetch("VIDEO_S3_BUCKET_NAME"),
    signing_ttl: 1.hour
  )

  segment_duration 4
end

# app/videos/course_video.rb
class CourseVideo < ApplicationVideo
  rendition :high,   scale: 1.0
  rendition :medium, scale: 0.5
  rendition :small,  scale: 0.25

  poster :hero,      scale: 1.0
  poster :thumbnail, width: 320, height: 180
end
```

### Encode and upload

```ruby
profile = CourseVideo.new(
  input: HLS::Input.new("lecture.mp4"),
  output: Pathname.new("tmp/encoded"),
  key_prefix: "courses/phlex/intro"
)
profile.process
# Probes input → encodes HLS multiplex + posters → uploads to bucket.
# Idempotent: re-running with the same input is a no-op.
```

Or enqueue the work asynchronously:

```ruby
HLS::EncodeJob.perform_later(
  profile: "CourseVideo",
  input:  "lecture.mp4",
  output: "tmp/encoded",
  key_prefix: "courses/phlex/intro"
)
```

### Serve from a controller

```ruby
class VideosController < ApplicationController
  before_action { @manifest = CourseVideo.manifest(params[:id]) }

  def index
    respond_to do |format|
      format.m3u8 { render plain: @manifest.master_playlist }
      format.jpg  { redirect_to @manifest.poster_url(:hero), allow_other_host: true }
    end
  end

  def show
    variant = @manifest.variant(params[:variant])
    render plain: variant.playlist
  end
end
```

`master_playlist` rewrites variant URIs to a controller-routable shape;
`variant.playlist` rewrites segment URIs to pre-signed S3 URLs that
the player can fetch directly.

### Preview windows

`Variant#[range]` slices the variant to a duration in seconds. Useful
for locked-content previews:

```ruby
PREVIEW_DURATION = 30.seconds
list = if subscriber?
  @manifest.variant(params[:variant]).playlist
else
  @manifest.variant(params[:variant])[0...PREVIEW_DURATION].playlist
end
```

### Testing your profile

The gem ships test helpers for verifying that your profile produces a
correct bundle end-to-end:

```ruby
require "hls/testing"

RSpec.describe CourseVideo do
  include HLS::Testing

  it "produces a complete HLS bundle" do
    video = generate_test_video(duration: 12)
    output = Pathname.new(Dir.mktmpdir)

    profile = CourseVideo.new(input: HLS::Input.new(video), output: output)
    silence_ffmpeg { profile.encode!; profile.poster! }

    expect(output).to be_a_valid_hls_bundle
      .with_variants(3)
      .with_posters(:hero, :thumbnail)
  end
end
```

### Codec auto-detection

By default `video_codec :h264` resolves to the best available encoder
on the host (`h264_videotoolbox` on macOS, `h264_nvenc`/`h264_qsv` on
Linux GPUs, `libx264` as the universal fallback). Override per-profile
when you need an explicit one:

```ruby
class WebVideo < ApplicationVideo
  video_codec "libx264"   # always software, regardless of host
end
```

### Configuration reference

Every class-level setting on `HLS::ApplicationVideo` is inheritable
through the class hierarchy. For static values, set with the DSL form
(`segment_duration 4`); for dynamic values that should re-read on
every Zeitwerk reload, override the reader (`def self.storage = ...`).

| Setting              | Default              | Notes |
|----------------------|----------------------|-------|
| `storage`            | _none — required_    | `HLS::Storage::S3`, `HLS::Storage::Memory`, or any conforming adapter |
| `segment_duration`   | `4`                  | HLS segment length, seconds |
| `video_codec`        | `:h264`              | Symbol (auto-resolved) or string (explicit) |
| `audio_codec`        | `"aac"`              | |
| `audio_bitrate`      | `128`                | kbps |
| `bits_per_pixel`     | `:mixed` (4)         | `:screencast` (3), `:mixed` (4), `:motion` (6) |
| `max_bitrate_kbps`   | `15_000`             | Caps scaled-rendition bitrate |
| `ffmpeg_timeout`     | `nil`                | Hard cap (seconds) on a single ffmpeg run; `nil` disables |
| `cache`              | `nil`                | `HLS::Cache` (groups a `Rails.cache`-shaped backend with a TTL) or any object responding to `fetch(key, &block)` |

`HLS::Storage::S3` itself takes `bucket_name:`, `signing_ttl:`, and an
optional `s3_resource:` (defaults to `HLS.s3_resource`). For tests or
non-AWS backends, use `HLS::Storage::Memory.new(name: ...)` or any
object responding to `signing_ttl` and `object(key)`.

`HLS.s3_resource` is process-global. If two profiles need different
SDK clients (different regions, credentials, or endpoints), pass
`s3_resource:` directly to each `HLS::Storage::S3` rather than relying
on the global default:

```ruby
class CourseVideo < ApplicationVideo
  def self.storage = HLS::Storage::S3.new(
    s3_resource: Aws::S3::Resource.new(region: "us-west-2", ...),
    bucket_name: "course-videos",
    signing_ttl: 1.hour
  )
end
```

### Concurrency and retries

The uploader runs PUTs in parallel with bounded concurrency and retries
transient failures with exponential backoff. Defaults are tuned for
typical home/office connections; override per-call:

```ruby
HLS::Uploader.new(
  storage: storage, output: out, key_prefix: prefix, state: state,
  concurrency: 8,        # default 4
  max_retries: 5,        # default 3
  initial_backoff: 0.25  # default 0.5 seconds, doubles per attempt
).perform
```

Only transient errors (network timeouts, 503s, throttling) are retried;
permanent errors (NoSuchBucket, 403) fail fast.

### Instrumentation

The gem publishes ActiveSupport::Notifications events when AS is
loaded. Subscribe to wire up logging or metrics:

```ruby
ActiveSupport::Notifications.subscribe("encode.hls") do |name, start, finish, _, payload|
  Rails.logger.info "[hls] encoded #{payload[:profile]} in #{((finish - start) * 1000).round}ms"
end
```

Events:

| Name                | Payload keys                                |
|---------------------|---------------------------------------------|
| `encode.hls`        | `profile`, `output`, `renditions`           |
| `poster.hls`        | `profile`, `output`, `count`                |
| `verify.hls`        | `profile`, `output`                         |
| `upload_object.hls` | `key`, `bytes`, `content_type`              |
| `upload_retry.hls`  | `key`, `attempt`, `error`, `message`        |
| `process.hls`       | `profile`, `key_prefix`, `uploaded`, `skipped` |

### Storage adapters

The default backend is `HLS::Storage::S3`, which wraps an
`Aws::S3::Bucket` (works with AWS S3, Tigris, Cloudflare R2, MinIO).
`HLS::Storage::Memory` ships as a no-network adapter useful for tests.
Roll your own by implementing the protocol — `signing_ttl` plus
`object(key)` returning something that responds to `get`,
`put(body:, content_type:, cache_control:)`, and
`presigned_url(:get, expires_in:)`.

#### MinIO

MinIO is API-compatible with S3 — point `HLS.s3_resource` at its
endpoint:

```ruby
# config/initializers/hls.rb
HLS.s3_resource = Aws::S3::Resource.new(
  access_key_id:     ENV["MINIO_ACCESS_KEY"],
  secret_access_key: ENV["MINIO_SECRET_KEY"],
  endpoint:          ENV["MINIO_ENDPOINT"], # e.g. http://localhost:9000
  region:            "us-east-1",
  force_path_style:  true                   # required for MinIO
)

# app/videos/application_video.rb
class ApplicationVideo < HLS::ApplicationVideo
  def self.storage = HLS::Storage::S3.new(
    bucket_name: ENV.fetch("MINIO_BUCKET"),
    signing_ttl: 1.hour
  )
end
```

`force_path_style: true` is the key MinIO requirement — MinIO doesn't
do virtual-hosted-style addressing.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/beautifulruby/hls.
