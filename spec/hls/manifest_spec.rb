# frozen_string_literal: true

require "spec_helper"

RSpec.describe HLS::Manifest do
  # Sample HLS playlists that mimic what ffmpeg writes for a 3-rendition
  # bundle. Each variant has 3 segments at 4 seconds each (12s total).
  let(:master_m3u8) do
    <<~M3U8
      #EXTM3U
      #EXT-X-VERSION:6
      #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
      0/index.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"
      1/index.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480,CODECS="avc1.640028,mp4a.40.2"
      2/index.m3u8
    M3U8
  end

  let(:variant_m3u8) do
    <<~M3U8
      #EXTM3U
      #EXT-X-VERSION:6
      #EXT-X-TARGETDURATION:4
      #EXT-X-PLAYLIST-TYPE:VOD
      #EXTINF:4.000,
      0.ts
      #EXTINF:4.000,
      1.ts
      #EXTINF:4.000,
      2.ts
      #EXT-X-ENDLIST
    M3U8
  end

  let(:bucket) do
    StubbedBucket.build(
      name: "videos",
      objects: {
        "course/01/index.m3u8"   => master_m3u8,
        "course/01/0/index.m3u8" => variant_m3u8,
        "course/01/1/index.m3u8" => variant_m3u8,
        "course/01/2/index.m3u8" => variant_m3u8
      }
    )
  end

  subject(:manifest) do
    described_class.new(
      bucket: bucket,
      path: "course/01",
      expires_in: 3600,
      segment_duration: 4
    )
  end

  describe "#poster_url" do
    it "returns a pre-signed URL for poster.jpg under the manifest path" do
      url = manifest.poster_url
      expect(url).to include("/course/01/poster.jpg")
      expect(url).to include("X-Amz-Expires=3600")
    end
  end

  describe "#presigned_url" do
    it "joins extra path parts under the manifest path" do
      url = manifest.presigned_url("custom.jpg")
      expect(url).to include("/course/01/custom.jpg")
    end

    it "accepts a custom expires_in override" do
      url = manifest.presigned_url("custom.jpg", expires_in: 60)
      expect(url).to include("X-Amz-Expires=60")
    end
  end

  describe "#master_playlist" do
    it "rewrites variant URIs to <id>/<index>.m3u8 (relative to the master URL)" do
      # The variant URIs in the master must resolve correctly when a
      # player fetches the master at /videos/<path>/<id>.m3u8 and asks
      # for a relative variant. With path=course/01, basename is "01",
      # so URIs read 01/0.m3u8 and the player resolves to
      # /videos/course/01/0.m3u8 — matching the show route.
      list = manifest.master_playlist
      uris = list.items.map(&:uri)
      expect(uris).to eq([
        "01/0.m3u8",
        "01/1.m3u8",
        "01/2.m3u8"
      ])
    end

    it "uses a custom variant_uri callable when one is supplied" do
      custom = HLS::Manifest.new(
        bucket: bucket,
        path: "course/01",
        expires_in: 3600,
        variant_uri: ->(path:, variant_index:) { "/streams/#{path}/v#{variant_index}" }
      )

      uris = custom.master_playlist.items.map(&:uri)
      expect(uris).to eq([
        "/streams/course/01/v0",
        "/streams/course/01/v1",
        "/streams/course/01/v2"
      ])
    end

    # Behavioral regression test for the URI-doubling bug. A real HLS
    # player fetches the master playlist at a URL, then resolves each
    # relative variant URI *against that URL* per RFC 3986. If the
    # variant URIs include the master's path prefix, resolution doubles
    # it and the player requests a non-existent route. This test
    # simulates that resolution and asserts the result matches the
    # expected show-route shape.
    it "produces variant URIs that resolve correctly under the master playlist URL" do
      master_url = URI("https://app.example.com/videos/course/01.m3u8")

      resolved = manifest.master_playlist.items.map { |item| (master_url + item.uri).to_s }

      expect(resolved).to eq([
        "https://app.example.com/videos/course/01/0.m3u8",
        "https://app.example.com/videos/course/01/1.m3u8",
        "https://app.example.com/videos/course/01/2.m3u8"
      ])
    end

    it "does not double the master path when resolved (catches the path-doubling regression)" do
      master_url = URI("https://app.example.com/videos/course/01.m3u8")
      master_path_without_ext = "/videos/course/01"

      manifest.master_playlist.items.each do |item|
        resolved = (master_url + item.uri).to_s
        # The master path segment must appear exactly once in the
        # resolved URL. If it appears twice, the variant URI included
        # the path prefix and resolved relative to the master's parent.
        occurrences = resolved.scan(master_path_without_ext).size
        expect(occurrences).to eq(1),
          "variant URI #{item.uri.inspect} resolved to #{resolved.inspect} " \
          "which contains #{master_path_without_ext.inspect} #{occurrences} times (expected 1)"
      end
    end

    it "preserves three variants for a three-rendition master" do
      expect(manifest.master_playlist.items.size).to eq(3)
    end

    it "is non-mutating — calling it doesn't break #variants" do
      # Regression: an earlier impl mutated the cached raw playlist's
      # items in place, which corrupted variant discovery on a second
      # call within the same request.
      manifest.master_playlist
      expect(manifest.variants.map(&:variant_path)).to eq(%w[0 1 2])
    end

    it "returns independent objects on each call" do
      first = manifest.master_playlist
      second = manifest.master_playlist
      expect(first.items.first.equal?(second.items.first)).to be(false)
    end
  end

  describe "#variants" do
    it "returns one Variant per master playlist entry" do
      expect(manifest.variants.size).to eq(3)
    end

    it "labels each variant by its ffmpeg-emitted index path" do
      expect(manifest.variants.map(&:variant_path)).to eq(%w[0 1 2])
    end

    it "loads each variant's segments" do
      expect(manifest.variants.first.items.size).to eq(3)
    end
  end

  describe "#variant" do
    it "looks up by ffmpeg index path" do
      expect(manifest.variant("1").variant_path).to eq("1")
    end

    it "returns nil for an unknown index" do
      expect(manifest.variant("99")).to be_nil
    end
  end

  describe "playlist caching" do
    let(:cache) do
      store = {}
      Class.new {
        define_method(:fetch) { |key, expires_in: nil, &block|
          store[key] ||= [block.call, expires_in]
          store[key].first
        }
        define_method(:store) { store }
      }.new
    end

    it "uses the supplied cache when fetching playlists" do
      cache_inst = cache
      m1 = described_class.new(
        bucket: bucket, path: "course/01", expires_in: 3600,
        segment_duration: 4, cache: cache_inst, cache_ttl: 60
      )
      m1.master_playlist
      expect(cache_inst.store.keys).to include("hls/manifest/course/01/index.m3u8")
    end

    it "passes cache_ttl through to the cache backend" do
      cache_inst = cache
      m1 = described_class.new(
        bucket: bucket, path: "course/01", expires_in: 3600,
        segment_duration: 4, cache: cache_inst, cache_ttl: 90
      )
      m1.master_playlist
      _body, ttl = cache_inst.store["hls/manifest/course/01/index.m3u8"]
      expect(ttl).to eq(90)
    end

    it "does not hit the bucket again on a cache hit" do
      hits = 0
      bucket = StubbedBucket.build(
        name: "videos",
        objects: {
          "course/01/index.m3u8"   => master_m3u8,
          "course/01/0/index.m3u8" => variant_m3u8,
          "course/01/1/index.m3u8" => variant_m3u8,
          "course/01/2/index.m3u8" => variant_m3u8
        }
      )
      # Wrap the bucket's `object` to count gets.
      original_object_method = bucket.method(:object)
      counter = ->(key) {
        original_object_method.call(key).tap do |obj|
          orig_get = obj.method(:get)
          obj.define_singleton_method(:get) do |*a|
            hits += 1
            orig_get.call(*a)
          end
        end
      }
      bucket.define_singleton_method(:object) { |k| counter.call(k) }

      cache_inst = cache
      m1 = described_class.new(
        bucket: bucket, path: "course/01", expires_in: 3600,
        segment_duration: 4, cache: cache_inst
      )
      m1.master_playlist
      first_hits = hits

      m2 = described_class.new(
        bucket: bucket, path: "course/01", expires_in: 3600,
        segment_duration: 4, cache: cache_inst
      )
      m2.master_playlist

      expect(hits).to eq(first_hits)
    end
  end
end

RSpec.describe HLS::Manifest::Variant do
  let(:variant_m3u8) do
    <<~M3U8
      #EXTM3U
      #EXT-X-VERSION:6
      #EXT-X-TARGETDURATION:4
      #EXTINF:4.000,
      0.ts
      #EXTINF:4.000,
      1.ts
      #EXTINF:4.000,
      2.ts
      #EXTINF:4.000,
      3.ts
      #EXTINF:4.000,
      4.ts
      #EXTINF:4.000,
      5.ts
      #EXTINF:4.000,
      6.ts
      #EXTINF:4.000,
      7.ts
      #EXTINF:4.000,
      8.ts
      #EXT-X-ENDLIST
    M3U8
  end

  let(:bucket) do
    StubbedBucket.build(
      name: "videos",
      objects: {
        "course/01/0/index.m3u8" => variant_m3u8
      }
    )
  end

  let(:manifest) do
    HLS::Manifest.new(
      bucket: bucket,
      path: "course/01",
      expires_in: 3600,
      segment_duration: 4
    )
  end

  let(:items) { M3u8::Reader.new.read(variant_m3u8).items }

  subject(:variant) do
    described_class.new(manifest: manifest, variant_path: "0", items: items)
  end

  describe "#duration" do
    it "is segment count * segment_duration" do
      expect(variant.duration).to eq(36) # 9 * 4
    end
  end

  describe "#[range]" do
    it "rounds down for inclusive ranges" do
      # 30s / 4s = 7.5 → floor → 7 segments → 28s of video
      sliced = variant[0..30]
      expect(sliced.items.size).to eq(7)
    end

    it "rounds up for exclusive ranges" do
      # 30s / 4s = 7.5 → ceil → 8 segments → 32s of video
      sliced = variant[0...30]
      expect(sliced.items.size).to eq(8)
    end

    it "returns a new Variant, not a mutated copy" do
      sliced = variant[0...30]
      expect(sliced).to be_a(HLS::Manifest::Variant)
      expect(variant.items.size).to eq(9) # original untouched
    end

    it "raises on non-Range arguments" do
      expect { variant[5] }.to raise_error(ArgumentError, /Range/)
    end
  end

  describe "#playlist" do
    it "rewrites each segment to a pre-signed URL" do
      list = variant.playlist
      list.items.each do |item|
        expect(item.segment).to start_with("https://")
        expect(item.segment).to include("X-Amz-Signature")
        expect(item.segment).to include("/course/01/0/")
      end
    end

    it "preserves segment count" do
      expect(variant.playlist.items.size).to eq(9)
    end

    it "doesn't mutate the underlying items" do
      variant.playlist
      expect(variant.items.first.segment).to eq("0.ts") # still unsigned
    end
  end
end

RSpec.describe HLS::ApplicationVideo, ".manifest" do
  let(:bucket) { StubbedBucket.build(name: "test-bucket") }
  let(:profile_class) do
    bucket_obj = bucket
    Class.new(described_class).tap do |k|
      k.bucket bucket_obj
      k.signing_ttl 1800
      k.segment_duration 4
    end
  end

  it "returns a Manifest bound to the profile's bucket and TTL" do
    manifest = profile_class.manifest("foo/bar")
    expect(manifest).to be_a(HLS::Manifest)
    expect(manifest.path).to eq("foo/bar")
    expect(manifest.expires_in).to eq(1800)
    expect(manifest.segment_duration).to eq(4)
  end

  it "lets the caller override expires_in" do
    manifest = profile_class.manifest("foo/bar", expires_in: 60)
    expect(manifest.expires_in).to eq(60)
  end

  it "raises a helpful error when bucket is unset" do
    klass = Class.new(described_class)
    expect { klass.manifest("foo") }.to raise_error(ArgumentError, /no bucket configured/)
  end

  it "treats an empty-string bucket the same as nil (env-var fallback case)" do
    klass = Class.new(described_class).tap { |k| k.bucket "" }
    expect { klass.manifest("foo") }.to raise_error(ArgumentError, /no bucket configured/)
  end

  it "raises ArgumentError for a bucket of an unsupported type" do
    klass = Class.new(described_class).tap { |k| k.bucket 12345 }
    expect { klass.manifest("foo") }.to raise_error(ArgumentError, /Unsupported bucket value/)
  end

  it "resolves a string bucket through HLS.s3_resource" do
    fake_resource = instance_double(Aws::S3::Resource)
    fake_bucket = instance_double(Aws::S3::Bucket)
    allow(fake_resource).to receive(:bucket).with("named-bucket").and_return(fake_bucket)

    klass = Class.new(described_class).tap { |k| k.bucket "named-bucket" }

    HLS.s3_resource = fake_resource
    begin
      manifest = klass.manifest("foo")
      expect(manifest.bucket).to eq(fake_bucket)
    ensure
      HLS.s3_resource = nil
    end
  end
end
