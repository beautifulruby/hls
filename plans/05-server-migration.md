# 05 — Server migration

## Goal

Land everything from steps 01-04 in `../server` without breaking the
live course at beautifulruby.com. The currently-deployed `Video` model
+ `VideosController` keep working through every intermediate state.

## Preconditions

- [01](01-profile-dsl.md), [02](02-upload-pipeline.md),
  [03](03-reader-and-manifest.md), [04](04-codec-portability.md) all
  done. Gem is releasable on its own.

## Work

### 1. Pin gem to local path during migration

In `../server/Gemfile`:

```ruby
gem "hls", path: "../hls"
```

Bundle. Run server. Verify nothing breaks before changing any server
code (the new gem should still be backwards-compatible with the old
`HLS::Video::Scalable` API used by `examples/directory.rb`).

### 2. Add profile classes

Create:

- `../server/app/videos/application_video.rb` — sets bucket from
  `VIDEO_S3_BUCKET_NAME`, signing TTL `1.hour`,
  `segment_duration 4` (matches today's `Video::SEGMENT_DURATION`).
- `../server/app/videos/course_video.rb` — three scaled renditions
  matching `HLS::Video::Scalable`'s 1.0 / 0.5 / 0.25 split.

### 3. Cut the controller over to `Manifest`

Edit `../server/app/controllers/videos_controller.rb`:

- Replace `@video = Video.new(path: video_path, expires_in: ...)` with
  `@manifest = CourseVideo.manifest(video_path)`.
- `format.m3u8` index: drop the inline URI rewriting loop
  (`videos_controller.rb:36-40`); the manifest handles it.
- `format.m3u8` show: keep the `variant.find { ... }` lookup and the
  `variant[0...PREVIEW_DURATION]` slice; both still work because
  `Manifest::Variant` is a verbatim move from `Video::Variant`.
- `format.jpeg`: replace `@video.poster_url` with
  `@manifest.poster_url`.

Run the existing controller specs (if they exist) or smoke-test by
hitting `/videos/<known-id>.m3u8` and diffing the response against a
saved baseline.

### 4. Delete `app/models/video.rb`

Once the controller no longer references it, delete
`../server/app/models/video.rb`. Search for any other call sites
(`grep -r "\bVideo\.new" ../server/app`); migrate or remove.

`VideoPlan` (`../server/app/plans/video_plan.rb`) operates on
`@video_page`, not on `Video`, so it should be unaffected — verify.

### 5. Add the encode pipeline to the server

Replace the local-disk script (`hls/examples/directory.rb`) with an
ActiveJob-backed flow:

- Create `../server/app/jobs/encode_course_video_job.rb` that wraps
  `HLS::EncodeJob` with the `CourseVideo` profile.
- Wire whatever drops a new mp4 into the system to enqueue the job.
  Likely options: a CLI script `bin/encode-video <path>`, a watch
  folder, or a Rails admin form. Pick one — start with the CLI, defer
  the watch folder if not needed.

### 6. Verify on a sacrificial video

Encode a non-customer-facing test video through the new pipeline.
Verify:

- The bundle lands in Tigris under the expected key prefix.
- A second run is a no-op.
- Hitting `/videos/<test-id>.m3u8` plays the video in a real browser
  (Safari + Chrome with `hls.js` polyfill).

### 7. Cut over

- Tag the gem (`bundle exec rake release`).
- Switch `Gemfile` from `path:` to a version pin.
- Deploy `../server`.
- Re-encode existing videos through the new pipeline as needed (most
  should be fine since the storage layout matches what the old script
  produced — verify per video).

## Acceptance

- [x] All existing course videos still play after deploy. Spot-check
      ten across different courses.
- [x] Locked-content preview window still cuts off at 30s.
- [x] Twitter card poster still renders (`format.jpeg` path).
- [x] A new mp4 dropped through the new pipeline plays end-to-end in a
      browser.
- [x] `../server/app/models/video.rb` deleted; no dangling references.
- [x] `Gemfile` references a released gem version, not a `path:`.
- [x] Job queue (SolidQueue) processes encode jobs successfully on the
      production-shaped worker.

## Rollback plan

- Keep the previous gem version pinned in `Gemfile.lock` between the
  release commit and the deploy commit so a single `git revert` brings
  the old `Video` model back if something breaks.
- Sidecar state files in S3 are additive — they don't disturb the
  existing storage layout, so a rollback to the old reader doesn't see
  inconsistent state.

## Open questions

- Do we need a one-time backfill that writes `state.json` for already-
  encoded videos, so the new pipeline knows not to re-encode them?
  Probably yes for any video larger than a few hundred MB.
- Should `bin/encode-video` live in the gem (as a generic CLI) or in
  the server (as an app-specific script)? Probably the server, since
  it knows which profile class to use.
