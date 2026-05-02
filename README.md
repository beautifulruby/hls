# HLS

When I started working on the [Phlex on Rails video course](https://beautifulruby.com/phlex), I tried streaming mp4 files from an S3 compatible object store and quickly found out from users they were running into issues watching the video. I added to use [HLS](https://en.wikipedia.org/wiki/HTTP_Live_Streaming), but I quickly found out it's a bit of a pain setting that up on a private object store.

## Why?

Creating & serving HLS videos from private object stores is tricky.

### Sane encoding defaults

When you encode a video into HLS format, it cranks out different resolutions and bitrates that play on everything from mobile phones to TVs. You give it an input video and it writes out all the chunks into a directory.

### Generates pre-signed URLs in m3u8 playlists

The most annoying part about serving HLS videos from private object stores is generating pre-signed URLs for each chunk. This gem generates pre-signed URLs for each chunk in the m3u8 playlist, making it easy to serve HLS videos from private object stores.

### Rails integration

A Railtie autoloads `app/videos/*.rb` profile classes, wires app-wide
defaults from `config/initializers/hls.rb`, and ships an
`HLS::EncodeJob` ActiveJob wrapper for queue-driven encoding.

## Requirements

- Ruby 3.1+
- `ffmpeg` and `ffprobe` on the PATH (Homebrew, apt, or your distro
  equivalent)
- An S3-compatible bucket (Tigris, Cloudflare R2, AWS S3, MinIO, etc.)

## Support

Consider [buying a video course from Beautiful Ruby](https://beautifulruby.com) and learn a thing or two to keep the machine going that originally built this gem.

[![](https://immutable.terminalwire.com/NgTt6nzO1aEnExV8j6ODuKt2iZpY74ZF8ecpUSCp4A0tXA0ErpJIS4cdMX0tQQKOWwZSl65jWnpzpgCLJThhhWtZJGr42XKt7WIi.png)](https://beautifulruby.com/phlex/forms/overview)

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add hls
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install hls
```

## Usage

### Declare a profile

In a Rails app, `app/videos/*.rb` is autoloaded and inherits app-wide
defaults from `config/initializers/hls.rb`:

```ruby
# config/initializers/hls.rb
require "aws-sdk-s3"

Rails.application.config.hls.tap do |hls|
  hls.s3_resource = Aws::S3::Resource.new(
    access_key_id:     ENV["VIDEO_AWS_ACCESS_KEY_ID"],
    secret_access_key: ENV["VIDEO_AWS_SECRET_ACCESS_KEY"],
    endpoint:          ENV["VIDEO_S3_ENDPOINT_URL"],
    region:            "auto"
  )
  hls.bucket           = ENV.fetch("VIDEO_S3_BUCKET_NAME")
  hls.signing_ttl      = 1.hour
  hls.segment_duration = 4
end

# app/videos/application_video.rb
class ApplicationVideo < HLS::ApplicationVideo
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
through the class hierarchy and overridable by the host app's
`config.hls.*`:

| Setting              | Default              | Notes |
|----------------------|----------------------|-------|
| `bucket`             | _none — required_    | `Aws::S3::Bucket` or string name |
| `signing_ttl`        | `3600`               | Pre-signed URL lifetime, seconds |
| `segment_duration`   | `4`                  | HLS segment length, seconds |
| `video_codec`        | `:h264`              | Symbol (auto-resolved) or string (explicit) |
| `audio_codec`        | `"aac"`              | |
| `audio_bitrate`      | `128`                | kbps |
| `bits_per_pixel`     | `:mixed` (4)         | `:screencast` (3), `:mixed` (4), `:motion` (6) |
| `max_bitrate_kbps`   | `15_000`             | Caps scaled-rendition bitrate |

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/beautifulruby/hls.
