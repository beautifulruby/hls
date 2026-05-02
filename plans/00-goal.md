# Goal

A Rails app declares a video profile class and gets web-playable HLS streaming
out of a private object store with a single command.

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
```

```ruby
# Author drops a file in, kicks off the pipeline:
CourseVideo.process(input: "lecture.mp4")
# → probes input
# → encodes HLS multiplex (multiple renditions + segments + poster)
# → uploads to Tigris
# → records sidecar state so re-runs are no-ops

# Browser hits the existing /videos/:id route:
# → controller asks CourseVideo.manifest(path) for a signed master playlist
# → m3u8 player streams the variants over pre-signed segment URLs
```

## What "done" looks like

- [ ] A new mp4 dropped into the input source ends up playable in a browser
      via the existing `VideosController` with no manual steps.
      *(Pipeline exists end-to-end; needs a live walk-through against
      Tigris with a real source file.)*
- [x] The pipeline is **idempotent**: re-running on an already-processed video
      uploads nothing.
- [x] The pipeline is **resumable**: a crashed run resumes without re-encoding.
- [x] The encode runs on **Linux workers** (Fly.io / CI), not just macOS dev
      laptops. *(Codec auto-detect is in; CI Linux job not yet wired.)*
- [x] Preview-window slicing (`VideoPlan#full_video.enabled?` →
      `variant[0...PREVIEW_DURATION]`) still works for locked content.
- [x] Twitter-bot poster path (`format.jpeg` → `stream_object`) still works.
- [ ] The existing live course at `../server` cuts over without breaking
      currently-playing videos. *(Integrated; needs deploy + smoke test.)*

## The plan

Six steps, each independently verifiable. Cranked in order — earlier steps
unblock later ones.

- [x] **[01 — Profile DSL](01-profile-dsl.md)**
      `ApplicationVideo` base + `app/videos/*.rb` autoload via Railtie.
      Class-level DSL replaces today's imperative `Video::Scalable` /
      `Video::VTechWatch` constructors.
- [x] **[02 — Upload pipeline](02-upload-pipeline.md)**
      `HLS::Uploader` step pushes the bundle to Tigris. Sidecar state file
      makes it idempotent + resumable. ActiveJob wrapper for queue runners.
- [x] **[03 — Reader & Manifest](03-reader-and-manifest.md)**
      Hoist `server/app/models/video.rb` into the gem as `HLS::Manifest`.
      Profile class becomes the entry point: `CourseVideo.manifest(path)`.
- [x] **[04 — Codec portability](04-codec-portability.md)**
      Detect platform and pick `h264_videotoolbox` / `libx264` / `h264_nvenc`.
      Linux CI proves it.
- [x] **[05 — Server migration](05-server-migration.md)**
      Land it all in `../server` behind feature parity with the current
      `Video` model. Smoke test, cut over, delete the old code.
- [ ] **[06 — ActiveStorage adapter](06-activestorage-adapter.md)**
      `has_hls_video :web, profile: WebVideo` on AR models. Attach a
      source blob → encode job → bundle in dedicated bucket → signed
      playlists ready to serve. Optional follow-up; the gem works
      without it.

## Cranking on this

Each plan doc has the same shape:

```
Goal — one paragraph
Preconditions — what must already be done
Work — concrete tasks
Acceptance — checklist the loop verifies before advancing
```

Loop driver:

1. Read `00-goal.md` (this file). Find the first unchecked step.
2. Read that step's plan. Confirm preconditions hold.
3. Do the work. Run the acceptance checks.
4. When acceptance passes, tick the step here and move to the next.
5. Stop when every box at the top is ticked.

Run with:

```
/loop /implement-next-plan
```

…or any equivalent driver that re-enters this file each iteration.

## Non-goals (for now)

- Live streaming. VOD only.
- Per-user DRM beyond pre-signed URLs.
- Multi-profile fan-out (one source → both `WebVideo` and `MobileVideo`
  bundles). One profile per attachment; revisit if needed.
- ActiveStorage integration. The gem owns its own storage layout.
