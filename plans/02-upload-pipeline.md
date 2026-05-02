# 02 — Upload pipeline

## Goal

After ffmpeg writes the HLS bundle to a local working directory, push every
file (master playlist, variant playlists, segments, poster) to the profile's
configured bucket. Track what got uploaded so re-runs are no-ops and crashed
runs resume.

```ruby
CourseVideo.process(input: "lecture.mp4")
# probe → encode → upload → state.json
# Re-run → reads state.json, does nothing.
# Crashed mid-upload → resumes from last successful key.
```

## Preconditions

- [01 — Profile DSL](01-profile-dsl.md) done. `CourseVideo.bucket` and
  `CourseVideo.new(input:, output:)#process` exist.

## Work

### 1. `HLS::Uploader` step

In `lib/hls/uploader.rb`:

- `Uploader.new(profile:, output:, bucket:, key_prefix:)`
- `#perform` walks `output` recursively, uploads each file to
  `bucket.object(key_prefix + relative_path)`.
- Sets `Content-Type` correctly per extension (m3u8, ts, jpg).
- Sets `Cache-Control: public, max-age=31536000, immutable` for segments
  and posters; shorter (or no-cache) for playlists.
- Computes a content hash (SHA256 or MD5/etag) per file before upload;
  skips upload if remote etag matches.

### 2. Sidecar state file

`output/.hls-state.json` records:

```json
{
  "input_digest": "sha256:...",
  "profile": "CourseVideo",
  "renditions": [
    { "name": "full",   "width": 1920, "height": 1080, "bitrate": 5000 },
    { "name": "medium", "width": 960,  "height": 540,  "bitrate": 1500 }
  ],
  "encoded_at": "2026-05-01T20:14:00Z",
  "uploads": {
    "index.m3u8":            { "etag": "...", "uploaded_at": "..." },
    "0/index.m3u8":          { "etag": "...", "uploaded_at": "..." },
    "0/0.ts":                { "etag": "...", "uploaded_at": "..." }
  }
}
```

- Encode step writes `input_digest`, `renditions`, `encoded_at`. Skips
  encode if digest matches and all rendition output files exist.
- Upload step writes the `uploads` map incrementally, one entry per
  successful PUT. Skips already-uploaded keys whose local hash matches
  the recorded etag.

### 3. Pipeline orchestration on the profile

```ruby
class HLS::ApplicationVideo
  def process
    probe!                 # ffprobe → input metadata
    encode! unless encoded?
    upload! unless uploaded?
    state.save
  end
end
```

Failure semantics:

- Probe failure → raise, no state written.
- Encode failure → raise, partial output left on disk (next run's
  `encoded?` check sees missing files and re-encodes).
- Upload failure → raise, state.json captures progress so far.

### 4. ActiveJob wrapper

In `lib/hls/encode_job.rb`:

```ruby
class HLS::EncodeJob < ActiveJob::Base
  def perform(profile_class_name, input_path, output_path)
    profile = profile_class_name.constantize
    profile.new(input: HLS::Input.new(input_path),
                output: Pathname.new(output_path)).process
  end
end
```

- App enqueues with whatever queue adapter it uses (the server uses
  SolidQueue per its Procfile.dev).
- Single job per video. The multiplex (multiple ffmpeg renditions in one
  invocation) keeps it from needing fan-out.

### 5. Drop `Parallel.each` default

Today `lib/hls.rb:350-355` runs N ffmpegs concurrently using
`Etc.nprocessors - 1`. Each ffmpeg already multithreads internally, so
this thrashes on most machines. Change `HLS::Jobs#process` default to
`in_processes: 1`. Keep the knob; document the trade-off.

### 6. Subprocess error handling

`HLS::Jobs#ffmpeg` (lib/hls.rb:364-369) uses bare `system(*cmd)` which
ignores the exit status. Replace with one of:

- `system(*cmd, exception: true)` (raises on non-zero), or
- A `Process.spawn` + `Process.wait2` pattern that captures stderr for
  the error message.

## Acceptance

- [x] `bin/rails runner 'CourseVideo.new(input: HLS::Input.new("spec/fixtures/sample.mp4"), output: Pathname.new("tmp/out")).process'`
      produces a complete bundle in Tigris (or in a stubbed S3 in tests).
- [x] Re-running the same command issues zero PUT requests.
- [x] Killing the process mid-upload and re-running completes only the
      remaining keys.
- [x] Bumping the input file (different digest) triggers a full re-encode.
- [x] An ffmpeg failure raises, doesn't silently mark the job complete.
- [x] `HLS::EncodeJob` enqueues and runs end-to-end against a SolidQueue
      worker in `spec/dummy`.
- [x] Upload step verified against a stubbed S3 client (no live Tigris
      calls in tests).

## Open questions

- Does `state.json` live in S3 alongside the bundle, in the local working
  dir, or both? Probably **both** — local for fast resume, S3 as the
  source of truth that survives ephemeral workers.
- Do we upload via threaded concurrency? S3 PUTs are I/O bound and a pool
  of ~8 threads would speed up large bundles materially. Default to
  threaded; size configurable.
