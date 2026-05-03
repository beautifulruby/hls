# CLAUDE.md

Guide for AI assistants and human maintainers working on this gem.
The README is for *users* of the gem; this file is for people
*changing* it.

## What this gem actually is

A Rails-friendly Ruby library for taking a video file, encoding it as
an HLS bundle (multi-rendition multiplex + posters), and serving it
from a private S3-compatible bucket via pre-signed URLs.

The user-facing surface is small:
- `HLS::ApplicationVideo` — DSL base class for `app/videos/*.rb`
  profile classes
- `HLS::Manifest` — read-side, returns signed playlists
- `HLS::Input` — ffprobe wrapper
- `HLS::Testing` — RSpec helpers for verifying user-defined profiles

Everything else (`Uploader`, `State`, `Codecs`, `Railtie`,
`EncodeJob`) is plumbing that profile classes orchestrate.

## Architecture & layering

```
L4  Framework integration   railtie.rb, encode_job.rb
L3  Orchestration           application_video.rb
L2  Storage                 manifest.rb (read), uploader.rb (write)
L1  Utilities               codecs, input, directory, state, testing,
                            version
```

Lower layers don't reach up. `Manifest` doesn't know `ApplicationVideo`
exists; `Uploader` doesn't know about `Manifest`. `ApplicationVideo`
is the only file that composes the layers, and it's the only file
users normally subclass.

The Railtie is *optional* — the gem works in plain Ruby. The Railtie
file is only required when `defined?(Rails::Railtie)` is true at
load time (see `lib/hls.rb` bottom).

## File map

```
lib/hls.rb                      Top-level module, error class, S3 resource accessor, requires
lib/hls/version.rb              Version constant
lib/hls/application_video.rb    DSL + encode/poster/upload orchestration
lib/hls/manifest.rb             Reads bundle from S3, returns signed M3u8 playlists
lib/hls/uploader.rb             Walks output dir, parallel idempotent S3 upload with retries
lib/hls/state.rb                JSON sidecar: input digest, encoded_at, per-key etags
lib/hls/lock.rb                 Advisory flock around the output dir during process
lib/hls/instrumentation.rb      ActiveSupport::Notifications wrapper (no-op without AS)
lib/hls/storage.rb              Storage protocol doc + Memory adapter for tests
lib/hls/codecs.rb               Logical → explicit codec resolution per host
lib/hls/input.rb                ffprobe wrapper (Open3, raises on failure)
lib/hls/directory.rb            Source-walking helper for batch encoding scripts
lib/hls/testing.rb              Public RSpec helpers + matcher (only when RSpec defined)
lib/hls/railtie.rb              Autoloads app/videos/, applies config.hls defaults
lib/hls/encode_job.rb           ActiveJob wrapper around profile.process

lib/generators/hls/install/     `bin/rails g hls:install` — initializer + ApplicationVideo
lib/generators/hls/video/       `bin/rails g hls:video NAME` — per-content-type profile
```

Each lib file has a matching spec under `spec/hls/`. Cross-cutting
specs (`process_spec.rb`, `poster_dsl_spec.rb`) live alongside.
End-to-end specs that shell out to ffmpeg live under `spec/integration/`.

## The pipeline

`profile.process` acquires a file lock on the output dir, then runs:

1. **Probe** — `HLS::Input` shells out to `ffprobe` for width / height
   / codec / duration / framerate. Lazy and memoized per Input
   instance. `validate!` is called before encode to fail fast on
   audio-only inputs.
2. **Encode** — `ApplicationVideo#encode!` builds an `ffmpeg` command
   from the rendition declarations + codec resolution. One ffmpeg
   invocation produces all renditions of the multiplex via
   `-filter_complex split` + `-var_stream_map`. Subject to
   `ffmpeg_timeout` and stderr is captured into `HLS::Error` on failure.
3. **Poster** — separate ffmpeg invocation if any `poster ...`
   declarations exist. Multiple outputs from one decode pass.
4. **Verify** — `verify_encode!` walks the output and asserts all
   expected files exist and are non-empty. Bails BEFORE recording state
   so a failed verify doesn't claim the bundle is encoded.
5. **Upload** — `HLS::Uploader` walks the output dir, computes MD5 of
   each file, skips files whose recorded digest in `state.json`
   matches. PUTs each file with appropriate Content-Type and
   Cache-Control. Default `concurrency: 4` parallel workers, with
   bounded retries on transient errors. Records etag back into state.

Idempotency is enforced at two levels:
- **Encode level**: skipped when the input's SHA256 digest matches
  what's recorded in state.json AND the master playlist file actually
  exists. Both checks are necessary — see "Common gotchas" below.
- **Upload level**: per-file MD5 compared to recorded digest.

## Class-level DSL pattern

`HLS::ApplicationVideo` uses a small custom inheritable-attribute
helper (`class_setting`) instead of pulling in ActiveSupport's
`class_attribute`. This keeps the gem usable without Rails.

The pattern: each setting is a singleton method that reads with no
args, writes with one. Reads walk the class hierarchy via `superclass`
until they find a set value or hit the default.

`renditions` and `posters` accumulate into per-class arrays. The
`inherited` callback dups parent declarations into subclasses, so
subclass mutations don't leak back to the parent.

Avoid the temptation to swap this for `class_attribute` unless we
later decide to take a hard dep on activesupport. Right now the gem's
only Rails-flavored deps are dev-only (railties, activejob).

## Storage layout

ffmpeg writes the bundle into `output/`:

```
<output>/
├── index.m3u8         master playlist
├── 0/                 first variant (highest rendition)
│   ├── index.m3u8
│   └── 0.ts, 1.ts, ...
├── 1/                 second variant
│   ├── index.m3u8
│   └── 0.ts, 1.ts, ...
├── 2/...
├── hero.jpg           if `poster :hero` declared
├── thumbnail.jpg      if `poster :thumbnail` declared
└── .hls-state.json    written by us, not uploaded
```

Variant names default to integer indices (`0/`, `1/`, `2/`) because
that's ffmpeg's default `%v` template substitution. Named variants via
`-var_stream_map name:high,...` is a known follow-up not yet built.

Bucket layout mirrors local layout under a `key_prefix`:

```
<bucket>/<key_prefix>/index.m3u8
<bucket>/<key_prefix>/0/index.m3u8
<bucket>/<key_prefix>/0/0.ts
...
```

## Read side: how URI rewriting works

The encoded master playlist points at variants by their relative path:

```
0/index.m3u8
1/index.m3u8
```

But the host app's controller wants to serve variants by their
*number* under a stable URL like `/videos/<id>/<variant>.m3u8`. So
`Manifest#master_playlist` rewrites:

```
0/index.m3u8  →  <path>/0.m3u8
1/index.m3u8  →  <path>/1.m3u8
```

The variant playlist (returned by `Variant#playlist`) goes a step
further: each segment URI gets rewritten to a pre-signed S3 URL the
player can fetch directly without proxying through the app server.

**Critical**: `master_playlist` must NOT mutate the cached raw
playlist. We had a regression where it did, which broke `variants`
when both were called in the same request (`File.dirname` of an
already-rewritten URI returns nonsense). There's a test pinning this.

## Codec resolution

`video_codec :h264` is a *logical* codec. At command-build time, the
gem picks the best available encoder by:

1. Checking `RbConfig::CONFIG["host_os"]` for darwin / linux / etc.
2. Querying `ffmpeg -encoders` once per process and caching the result
3. Walking the per-platform priority list (videotoolbox first on
   macOS; nvenc → qsv → libx264 on Linux)

To pin a specific encoder regardless of host, pass a string:
`video_codec "libx264"`. Tests stub `HLS::Codecs.platform` and
`available_encoders` to make platform-dependent paths deterministic.

## Common gotchas

### Variant URIs are RELATIVE to the master playlist URL

The master playlist served by the controller lives at e.g.
`/videos/<path>/<id>.m3u8`. Variant URIs inside it are RFC 3986
relative references — the player resolves each one against the
master's URL. A variant URI of `<id>/0.m3u8` resolves to
`/videos/<path>/<id>/0.m3u8` (good). A variant URI of
`<path>/<id>/0.m3u8` resolves to
`/videos/<path>/<path>/<id>/0.m3u8` — **the path doubles** —
because resolution drops the master URL's filename and joins
relative to the parent directory. We hit this once: it produced
`Aws::S3::Errors::NoSuchKey` when the player tried to fetch the
doubled URL.

`HLS::Manifest#master_playlist` produces the URI via the configured
`variant_uri` callable, defaulting to
`<basename(path)>/<index>.m3u8`. This default works for
`/videos/*path/:id/:variant.m3u8` Rails routes. For any other URL
shape, override `self.variant_uri(path:, variant_index:)` on the
profile class.

There's a regression test in `spec/hls/manifest_spec.rb` that
simulates the player's URL resolution with `URI#+`. Keep it. The
`HLS::Testing` matcher `resolve_variants_under(url)` is the
generalization users can run on their own profile specs.

### `path:` gem deps don't hot-reload

When the host app pins `gem "hls", path: "../hls"` for development,
gem source changes don't reload across the Rails process. After
changing gem code, fully restart the Rails server (Ctrl+C, `bin/dev`
again). Zeitwerk's reloader watches `app/`, not gems.

### `hls.js` caches master playlists in-memory

Even after a server-side fix lands, the player keeps the previously-
fetched master playlist in memory across plays in the same tab. If
debugging URL rewriting, hard-reload the browser tab (Cmd+Shift+R)
or open a private window to bypass it. The `Cache-Control: public,
max-age=300` we set on uploaded m3u8s is also strong enough to keep
old playlists around briefly.

### "Encoded but files missing"

If state.json exists but the output directory's been wiped (ephemeral
worker, manual cleanup, etc.), the naive `state.encoded?` check passes
but the upload step would try to walk an empty directory. The fix
(in `ApplicationVideo#encoded?`, private) checks BOTH state AND that
the master playlist is on disk. Keep this dual check — there's a test
for it.

### Empty-string buckets

`ENV.fetch("VIDEO_S3_BUCKET_NAME", "")` returns `""` when the env var
is missing. Empty string is truthy in Ruby. `resolve_bucket` treats
both `nil` and `""` as "no bucket configured" and raises. Don't
add another path that bypasses this check.

### Railtie initializer ordering

`config/initializers/hls.rb` in a host app sets `config.hls.bucket`,
which the gem's `apply_config` initializer reads. The Railtie's
initializer is declared `after: :load_config_initializers` so config
files run first. Without that ordering, the gem would read the config
*before* the host app set it. There's a regression test in
`spec/hls/railtie_spec.rb` against `spec/dummy/config/initializers/hls.rb`.

### State sidecar corruption

A malformed state.json would silently re-encode + re-upload everything
without telling the operator. We deliberately raise `HLS::State::CorruptError`
instead of recovering. If you hit this, delete the state file
intentionally rather than working around it in the gem.

### ffmpeg multithreading on macOS

On macOS with `h264_videotoolbox`, multiple concurrent ffmpeg
processes contend on the Media Engine and macOS's videotoolbox
session limits. `HLS_PARALLEL=1` is the safe default. Bumping it
helps on Linux with libx264 only if you have many small videos to
batch.

### Cache-control on m3u8

VOD playlists are immutable once written. We use `public, max-age=300`
(not `no-cache`) so CDNs can edge-cache them. A redeploy of a bundle
takes effect within 5 min. Don't tighten this without thinking about
CDN cost.

### GOP must equal framerate × segment_duration

ffmpeg's `-g` (GOP size) sets how many frames between keyframes. HLS
players seek to segment boundaries and need each segment to start with
a keyframe. Computed in `ApplicationVideo#gop_size` from
`input.framerate * segment_duration`. Hardcoding it (the previous bug)
caused stalls when segment_duration was set to anything other than the
"normal" value. Don't reintroduce a constant here.

### Lock file collides with stale interrupted runs only via Busy

`process` writes `.hls-lock` and `flock(LOCK_EX | LOCK_NB)`s it. A
second process gets `HLS::Lock::Busy` *immediately* — we don't wait.
The lock file itself stays on disk after release; only the kernel-level
advisory lock is dropped. The state.json + .hls-lock + .DS_Store + ._*
patterns are all skipped by the uploader.

### Storage protocol is duck-typed

`bucket` accepts anything responding to `object(key)` whose return
value implements `get` / `put(body:, content_type:, cache_control:)` /
`presigned_url(:get, expires_in:)`. The `Aws::S3::Bucket` already
matches; `HLS::Storage::Memory` is a test double; anything else is the
host app's responsibility. `resolve_bucket` returns duck-typed buckets
unchanged — it only special-cases String (via `HLS.s3_resource`) and
Aws::S3::Bucket (passthrough).

## Running tests

```sh
bundle exec rspec                           # everything (~35s, ffmpeg integration)
bundle exec rspec --exclude-pattern "spec/integration/**"   # unit only (~1s)
bundle exec rspec spec/hls/manifest_spec.rb # one file
```

The integration specs (`spec/integration/`) actually shell out to
ffmpeg. They generate a 12-second test source via
`HLS::Testing.generate_test_video` and verify output dimensions,
playlist structure, and segment counts. Slow but they're the test
that catches command-building bugs the stubbed unit tests miss.

The Rails-flavored specs (`spec/hls/railtie_spec.rb` and
`spec/integration/rails_pipeline_spec.rb`) share a single Rails app
boot via `spec/support/dummy_rails_app.rb`. Rails freezes
`autoload_paths` after `initialize!`, so booting twice in one process
crashes — always go through `DummyRailsApp.boot!`.

## Adding things

### A new codec

Edit `lib/hls/codecs.rb`:
- Add to `H264` if it's an h264 variant
- Add to `H264_PRIORITY[platform]` for auto-resolution
- Add a `case` arm in `ApplicationVideo#video_codec_options` for
  encoder-specific ffmpeg flags (preset, profile, tune, etc.)
- Add a spec covering both the resolution and the command-shape

### A new class-level setting

Add `class_setting :name, default: ...` near the bottom of the class
body in `application_video.rb`. If host apps should be able to
override it via `config.hls.name = ...`, add a corresponding line in
the Railtie's `apply_config` initializer.

### A new ffmpeg arg in the encode command

Edit `ApplicationVideo#command` (or one of `video_maps` / `audio_maps`).
**Add a unit test** asserting the new arg appears in the right place,
and check whether the integration spec's golden assertions need
updating.

### A new test helper

Add to `lib/hls/testing.rb`. Helpers can shell out (ffmpeg/ffprobe are
hard deps anyway) but should not require Rails. Custom matchers go
inside the `if defined?(RSpec::Matchers)` block at the bottom of that
file.

### A new Rails generator

Live under `lib/generators/hls/<name>/`:
- `<name>_generator.rb` — subclass `Rails::Generators::{Base,NamedBase}`
- `templates/*.rb` (or `.tt`) — Thor templates; `<%= %>` interpolates
  generator method results

Spec it under `spec/generators/`. Use the Rails helpers
(`Rails::Generators::Testing::{Behavior,Assertions}`) plus
`spec/support/minitest_shims.rb` so `assert_file` and friends work
inside RSpec. Always include a behavior test that `load`s the
generated file and asserts the resulting class actually works — text
matches don't catch wrong inheritance, missing renditions, etc.

## How this gem is used in `../server`

The sister project `../server` (beautifulruby.com) is the canonical
production consumer. Its `app/controllers/videos_controller.rb` is
~50 lines that delegates to `CourseVideo.manifest(path)`. Its
`config/initializers/hls.rb` configures the Tigris bucket. The legacy
`app/models/video.rb` was deleted during the integration in favor of
`HLS::Manifest`.

When making changes here that could affect the read side (Manifest,
URI rewriting, signed URLs), run the server suite too:

```sh
cd ../server && bundle exec rspec spec/requests/videos_spec.rb
```

## Plans directory

Long-form design docs live in `plans/`. The flow:

- `plans/00-goal.md` — the north star and master checklist
- `plans/0[1-5]-*.md` — implemented steps (all checked off)
- `plans/06-activestorage-adapter.md` — the next major chunk; not
  built yet

The format of each plan is consistent: Goal / Preconditions / Work /
Acceptance. The acceptance checklists are runnable — they're meant
to be the gate for marking the step complete.

## Things deliberately NOT in the gem

Rejected to keep scope tight:

- Live HLS / DASH support — VOD only
- DRM beyond pre-signed URLs
- Custom segment naming via post-encode rewriting (ffmpeg's templating
  covers what we need)
- Multi-profile fan-out from one source within a single `process` —
  use multiple profile instances if you need both `WebVideo` and
  `MobileVideo` outputs

## Release workflow

```sh
# 1. Bump lib/hls/version.rb
# 2. Move the [Unreleased] section in CHANGELOG.md under the new version
bundle exec rake release
```

This tags, pushes, and publishes to rubygems. There's no CI release
pipeline yet — releases are manual.
