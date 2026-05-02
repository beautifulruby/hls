# 06 — ActiveStorage adapter

## Goal

A user attaches an mp4 to a model via ActiveStorage. The HLS pipeline
runs automatically, lands a bundle in a dedicated bucket, and the model
exposes signed-URL playlists ready to hand to a video player. Reads
feel like ActiveStorage; writes are background-driven by the gem.

```ruby
class Course < ApplicationRecord
  has_one_attached :source_video                          # ActiveStorage
  has_hls_video :web,    profile: WebVideo                # Our gem
  has_hls_video :mobile, profile: MobileVideo             # Same source, different profile
end

course = Course.create!
course.source_video.attach(uploaded_file)
# A WebVideo encode job + a MobileVideo encode job get enqueued.

# Read side, no waiting necessary if the bundle is ready:
course.web.ready?               # bool
course.web.master_playlist_url  # signed URL the player consumes
course.web.poster_url(:hero)    # signed URL for the named poster
course.web.manifest             # raw HLS::Manifest if you need it
```

## Why this shape

- **Source stays in ActiveStorage** because that's what people already
  know and AS handles uploads, validations, file types. We don't want to
  reinvent the upload story.
- **Bundles live in a dedicated bucket** (separate from the AS bucket)
  because HLS bundles are 10-100× the size of the source, expire on
  different schedules, and benefit from CDN-friendly caching headers
  that don't fit AS conventions.
- **Multiple HLS profiles per source** because the same upload often
  needs different bundles (web, mobile, AppleTV) and re-encoding from
  the original is cheap relative to other options.
- **Profile classes are app/videos/*.rb** matching what step 01 already
  built — no new top-level concept.

## Preconditions

- [01](01-profile-dsl.md) — Profile DSL exists.
- [02](02-upload-pipeline.md) — Upload pipeline + EncodeJob exist.
- [03](03-reader-and-manifest.md) — Manifest exists.

## Work

### 1. Database schema

Add a migration:

```ruby
create_table :hls_bundles do |t|
  t.references :owner, polymorphic: true, null: false
  t.string :name,    null: false   # the has_hls_video name (e.g. "web")
  t.string :profile, null: false   # profile class name (e.g. "WebVideo")
  t.string :key_prefix, null: false # bucket key prefix
  t.string :status, null: false, default: "pending"
                                   # pending | encoding | ready | failed
  t.string :input_digest           # sha256 of the source blob
  t.json   :renditions             # array of resolved renditions
  t.string :error_message
  t.datetime :encoded_at
  t.timestamps

  t.index [:owner_type, :owner_id, :name], unique: true
end
```

`HLS::Bundle` is the AR model. Provides:
- `#ready?` / `#failed?` / `#pending?` / `#encoding?`
- `#manifest` — returns an `HLS::Manifest` for the configured profile + key_prefix
- `#master_playlist_url`, `#variant_playlist_url(name)`, `#poster_url(name)`
  — convenience that delegate to manifest

### 2. The `has_hls_video` macro

In `lib/hls/active_storage/macros.rb`:

```ruby
module HLS::ActiveStorage::Macros
  def has_hls_video(name, profile:, source: nil)
    # Define an AR association: has_one :<name>_hls_bundle, ->{ where(name: name) }, class_name: "HLS::Bundle"
    # Define a reader: def <name> = <name>_hls_bundle || build_<name>_hls_bundle
    # Register an after_attach hook on `source` (default: source_video)
    #   that enqueues HLS::EncodeJob with profile + bundle id
  end
end

ActiveRecord::Base.extend HLS::ActiveStorage::Macros
```

Loaded by the Railtie via `ActiveSupport.on_load(:active_record)`.

### 3. Encode trigger

When `source_video.attach(...)` happens:

1. AS fires `after_commit` on the attachment.
2. We compute the source blob's digest.
3. For each `has_hls_video` declaration on the model:
   - Find or create the matching `HLS::Bundle` row
   - Set `status: "pending"`, store `input_digest`
   - Enqueue `HLS::EncodeJob.perform_later(bundle_id: bundle.id)`

The EncodeJob:

1. Loads the bundle, sets `status: "encoding"`
2. Downloads the source blob to a tmpdir
3. Resolves the profile class
4. Runs `profile.new(input:, output:, key_prefix: bundle.key_prefix).process`
5. On success: `bundle.update!(status: "ready", encoded_at: Time.now, renditions: ...)`
6. On failure: `bundle.update!(status: "failed", error_message: e.message)` + re-raise

### 4. Key prefix derivation

Default: `"#{model.class.name.underscore}/#{model.id}/#{bundle.name}"`
e.g. `course/42/web`. Configurable via the macro:

```ruby
has_hls_video :web, profile: WebVideo, key_prefix: ->(model) { "videos/#{model.public_id}/web" }
```

### 5. Re-encoding when source changes

The `input_digest` lives on the bundle row. When `source_video.attach`
fires with a *new* blob:

- New digest != stored digest → enqueue encode (replacing the bundle)
- Same digest → no-op

This makes attaching the same file twice a no-op while still allowing
re-uploads to trigger re-encodes.

### 6. Cleanup

When the model is destroyed:

- `HLS::Bundle` rows go via `dependent: :destroy`
- A separate cleanup job deletes the bucket prefix (we don't block model
  destroy on S3 calls)

### 7. Generators

`bin/rails generate hls:install` — creates the migration, an
`app/videos/application_video.rb`, and a config initializer skeleton.

`bin/rails generate hls:profile WebVideo` — creates
`app/videos/web_video.rb` with a sensible rendition + poster default.

### 8. Tests

In `spec/integration/active_storage_spec.rb`:

- Boot dummy app with AS configured (already supported in spec/dummy?)
- Define a `Course` model with `has_one_attached :source_video` and
  `has_hls_video :web, profile: TestProfile`
- Attach the test fixture from `HLS::Testing.generate_test_video`
- Assert: `Course#web` returns a Bundle, status transitions
  `pending → encoding → ready` (with inline ActiveJob), bundle key
  prefix lands in the stub bucket, `manifest.master_playlist` works
- Assert: re-attaching the same file is a no-op
- Assert: attaching a different file re-enqueues
- Assert: destroying the course destroys the bundle row

## Acceptance

- [ ] `has_hls_video` macro is callable on `ActiveRecord::Base`
      subclasses inside a Rails app.
- [ ] Attaching to the configured source attribute enqueues an encode
      job.
- [ ] After the job runs, `model.<name>.ready?` is true and
      `model.<name>.master_playlist_url` returns a signed URL.
- [ ] The bucket key prefix follows the configured shape.
- [ ] Re-attaching the same source is a no-op.
- [ ] Re-attaching a different source triggers re-encoding.
- [ ] Multiple `has_hls_video` declarations on the same model produce
      independent bundles in independent profiles.
- [ ] Failed encodes mark the bundle `failed` with `error_message`
      populated.
- [ ] Generator commands work end-to-end against `spec/dummy`.
- [ ] Integration spec exercises the full attach → encode → manifest
      → signed URL path.

## Open questions

### Should bundles live in their own bucket or in the AS bucket?

**Probably their own.** Reasoning:
- HLS bundles are 10–100× the size of source uploads. Bucket-level
  budgeting matters.
- They have different cache-control / lifecycle rules
  (segments are immutable + long-cached, AS blobs aren't).
- They use different credentials in production (often different IAM
  policies for who can read/write).

The macro could accept `bucket: ...` to override. Default comes from
`Rails.application.config.hls.bucket`.

### Are HLS bundles ActiveStorage Variants in disguise?

**No, but related.** AS Variants:
- Are derivatives of *one* blob
- Are serialized into the URL itself (transformations encoded as
  signed params)
- Produce *one* output blob

HLS bundles:
- Are derivatives of one blob, BUT produce a directory tree, not a
  single file
- Need a database row to track encoding state (variants don't have state)
- Have multiple output objects per "variant" (the profile)

So the *interface* is variant-shaped (`course.web` feels like
`course.source_video.variant(:web)`) but the storage and lifecycle are
fundamentally different. A pure-Variant implementation would lose the
state tracking we need for async encodes.

### What about polymorphic bundles?

`HLS::Bundle` is `belongs_to :owner, polymorphic: true`, so any model
can `has_hls_video`. This is the standard AS pattern.

### Sidecar state vs DB

Step 02 has a `.hls-state.json` sidecar in the bucket. Once we have a DB
row, do we need both?

**Keep both.** The sidecar is the source of truth for the *bundle
contents* (which segments uploaded, etag/digest pairs); the DB row is
the source of truth for the *workflow* (status, input digest, encoded_at).
They serve different purposes:

- Sidecar survives a database wipe — bundle is reconstructable.
- DB row survives a bucket wipe — workflow state isn't lost.

The EncodeJob writes to both: the uploader maintains the sidecar
incrementally, the job updates the DB row at coarse milestones
(start/finish/fail).

### Migration path for existing course videos

The server already has Tigris-stored bundles encoded by the legacy
script. Two paths:

1. **Backfill**: a rake task creates `HLS::Bundle` rows pointing at
   existing key prefixes, status=`ready`, no source blob attached.
   Existing videos work; new ones go through AS.
2. **Re-encode**: re-attach existing sources through AS, let the
   pipeline produce new bundles. Higher cost, cleaner long-term.

Option 1 first; option 2 only if needed.
