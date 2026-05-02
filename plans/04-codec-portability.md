# 04 — Codec portability

## Goal

The encode runs on Linux workers (Fly.io, CI) and macOS dev laptops
without code changes. macOS picks `h264_videotoolbox` for speed; Linux
falls back to `libx264`. Profiles can override.

## Preconditions

- [01 — Profile DSL](01-profile-dsl.md) done — there's a place for the
  `video_codec` knob to live on the profile class.

## Work

### 1. Codec resolution

Resolution order, top wins:

1. Profile DSL: `video_codec encoder: "libx264"` (explicit string).
2. Profile DSL: `video_codec :h264` (logical, auto-resolved per host).
3. App-wide default: `Rails.application.config.hls.default_codec`.
4. Built-in default: `:h264`.

Logical → encoder mapping:

```ruby
HLS::Codecs::H264 = {
  videotoolbox: "h264_videotoolbox",   # macOS hardware
  nvenc:        "h264_nvenc",          # NVIDIA GPU
  qsv:          "h264_qsv",            # Intel QuickSync
  libx264:      "libx264"              # software fallback
}
```

### 2. Auto-detect

When the profile asks for `:h264` (logical), pick the first available
encoder by querying `ffmpeg -hide_banner -encoders` once at boot and
caching the list. Order:

- macOS: `videotoolbox` → `libx264`.
- Linux with `nvenc`: `nvenc` → `libx264`.
- Linux with `qsv`: `qsv` → `libx264`.
- Otherwise: `libx264`.

Don't shell out per encode; cache the encoder list at first use.

### 3. Per-encoder option blocks

`HLS::Video::Base#video_codec_options` (lib/hls.rb:183-201) already
branches on encoder name. Keep that pattern; add `h264_nvenc` and
`h264_qsv` blocks (preset, rate control). The existing libx264 block
stays.

### 4. CI

Add a Linux job (GitHub Actions, ubuntu-latest) that installs ffmpeg
and runs:

- `bundle exec rspec` (existing tests should pass on Linux).
- A small "encode a 5-second fixture" integration test that verifies
  output files exist and ffprobe reports the expected codec.

### 5. Removal

`HLS::Video::VTechWatch` is gone after step 01. The hardcoded
`VIDEO_CODEC = "h264_videotoolbox"` constant at `lib/hls.rb:79` becomes
the resolution rules above.

## Acceptance

- [x] `bundle exec rspec` passes on Linux CI.
- [x] CI integration test successfully encodes a fixture video using
      `libx264`.
- [x] On macOS, `CourseVideo.new(input:, output:).command` includes
      `h264_videotoolbox` (or whatever the profile resolves to).
- [x] On Linux (no GPU), the same call resolves to `libx264`.
- [x] Explicit `video_codec encoder: "libx264"` overrides auto-detect on
      both platforms.
- [x] No unconditional reference to `h264_videotoolbox` anywhere in the
      gem.

## Open questions

- Should we ship a Dockerfile fragment / Fly.io worker recipe with this
  plan, or leave it to the consuming app? Probably leave it; document
  the ffmpeg version we test against in the README.
- AV1 / HEVC support — out of scope. This step is H.264 only. Add a
  separate plan if that becomes interesting.
