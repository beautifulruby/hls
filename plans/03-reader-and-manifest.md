# 03 — Reader & Manifest

## Goal

Move the read-side logic — pre-signing, master/variant playlist
rewriting, range slicing for previews — out of the server and into the
gem. The Rails controller becomes a five-line shim that delegates to a
profile-aware manifest.

```ruby
# Today, in server/app/controllers/videos_controller.rb:
list = @video.master_playlist
list.items.each do |item|
  item.uri = File.join(params.fetch(:id), "#{File.dirname(item.uri)}.m3u8")
end
render plain: list

# After this step:
render plain: CourseVideo.manifest(video_path).master_playlist
```

## Preconditions

- [01 — Profile DSL](01-profile-dsl.md) done. Profiles know their
  `bucket` and `signing_ttl`.

## Work

### 1. Move `Video` and `Variant` into the gem

Source: `server/app/models/video.rb` (lines 1-119).

Target: `lib/hls/manifest.rb`.

Rename:

- `Video` → `HLS::Manifest`
- `Video::Variant` → `HLS::Manifest::Variant`

Keep:

- `presigned_url`, `master_playlist`, `variants`, `variant(index)` —
  unchanged in spirit.
- `Variant#[range]` slicing logic (the preview-window math at
  `video.rb:87-101`) — keep exactly as-is.
- `Variant#playlist` URI rewriting (`video.rb:103-112`) — keep.

Add:

- `Manifest#master_playlist` should do the URI rewrite the controller
  currently does inline (`videos_controller.rb:36-40`):
  joining `params[:id]` and turning each item.uri into
  `<id>/<dirname>.m3u8`. Make this part of the manifest, not the
  controller.

Drop:

- The hardcoded `Aws::S3::Resource` constant block at `video.rb:4-11`.
  The S3 client comes from the profile's configured bucket (set up in
  step 01 via the Railtie).

### 2. Profile entry point

```ruby
class HLS::ApplicationVideo
  def self.manifest(path, expires_in: signing_ttl)
    HLS::Manifest.new(
      bucket:,
      path:,
      expires_in:,
      segment_duration:
    )
  end
end
```

`CourseVideo.manifest("phlex/forms/overview")` returns a manifest bound
to the profile's bucket + TTL.

### 3. Poster handling

`Manifest#poster_url` keeps the `presigned_url("poster.jpg")` shape from
`video.rb:25-27`. Profile classes expose `poster_filename` (currently
hardcoded `"poster.jpg"` in `HLS::Poster::FILENAME`) so this stays in
sync.

### 4. Controller cleanup

In `server/app/controllers/videos_controller.rb`:

- Replace `@video = Video.new(...)` with
  `@manifest = CourseVideo.manifest(video_path)`.
- `format.m3u8` index → `render plain: @manifest.master_playlist`.
- `format.m3u8` show → `render plain: @manifest.variants.find(...) ...`.
  The preview slicing path (`variant[0...PREVIEW_DURATION]`) keeps the
  same shape since `Variant#[]` moved verbatim.
- `format.jpeg` → `@manifest.poster_url`.

### 5. Delete the old model

After step 05 ships, delete `server/app/models/video.rb`. Until then,
keep both forms working so the migration is reversible.

## Acceptance

- [x] `HLS::Manifest` exists in the gem with `master_playlist`,
      `variants`, `variant(i)`, `poster_url`, `presigned_url`.
- [x] `HLS::Manifest::Variant#[range]` slicing produces the same segment
      counts as today's `Video::Variant#[range]` — covered by the
      existing tests if they exist, or by new tests if they don't.
- [x] `CourseVideo.manifest(path).master_playlist` produces a playlist
      byte-identical to what `videos_controller.rb` produces today for a
      fixture bundle.
- [x] Pre-signed URL TTLs are sourced from the profile's `signing_ttl`.
- [x] `format.jpeg` poster path returns the same pre-signed URL shape
      (different signature, same key).
- [x] Tests verify URI rewriting against a stubbed S3 client.
- [x] No remaining references to `Aws::S3::Resource.new` in the server
      app outside of one config location (the Railtie wiring).

## Open questions

- Should `Manifest` accept any S3-compatible client, or be tied to
  `Aws::S3::Bucket`? Tied is fine; that's what the existing code does
  and what Tigris ships.
- Range/byte-range slicing for non-preview cases (e.g. chapter markers)
  — out of scope here, but the `Variant#[]` API is general enough that
  it can grow into that later.
