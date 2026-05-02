# frozen_string_literal: true

require "spec_helper"

RSpec.describe HLS::Storage::Memory do
  describe ".build" do
    it "preloads objects from a hash" do
      bucket = described_class.build(objects: { "a.txt" => "hello" })
      expect(bucket.object("a.txt").get.body.read).to eq("hello")
    end
  end

  describe HLS::Storage::Memory::Object do
    let(:bucket) { HLS::Storage::Memory.new(name: "test") }

    it "round-trips bytes through put/get" do
      bucket.object("foo").put(body: "bar")
      expect(bucket.object("foo").get.body.read).to eq("bar")
    end

    it "preserves the content_type passed to put" do
      bucket.object("foo.m3u8").put(body: "x", content_type: "application/vnd.apple.mpegurl")
      expect(bucket.object("foo.m3u8").get.content_type).to eq("application/vnd.apple.mpegurl")
    end

    it "raises KeyError for a missing object" do
      expect { bucket.object("nope").get }.to raise_error(KeyError)
    end

    it "returns an etag from put" do
      response = bucket.object("foo").put(body: "bar")
      expect(response.etag).to start_with('"').and end_with('"')
    end

    it "produces a deterministic memory:// presigned URL" do
      url = bucket.object("foo").presigned_url(:get, expires_in: 60)
      expect(url).to eq("memory://foo?expires_in=60")
    end
  end
end

RSpec.describe HLS::ApplicationVideo, "with a duck-typed bucket" do
  it "accepts any object responding to #object as a bucket" do
    storage = HLS::Storage::Memory.new(name: "v")
    klass = Class.new(described_class).tap { |k| k.bucket storage }
    expect(klass.resolve_bucket).to be(storage)
  end
end

RSpec.describe HLS::Manifest, "with the in-memory storage adapter" do
  let(:master_m3u8) do
    <<~M3U8
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=1000000
      0/index.m3u8
    M3U8
  end

  let(:variant_m3u8) do
    <<~M3U8
      #EXTM3U
      #EXTINF:4.0,
      0.ts
      #EXT-X-ENDLIST
    M3U8
  end

  let(:bucket) do
    HLS::Storage::Memory.build(
      name: "m",
      objects: {
        "course/01/index.m3u8"   => master_m3u8,
        "course/01/0/index.m3u8" => variant_m3u8
      }
    )
  end

  subject(:manifest) do
    described_class.new(bucket: bucket, path: "course/01", expires_in: 3600)
  end

  it "produces a master playlist via the in-memory adapter" do
    list = manifest.master_playlist
    expect(list.items.size).to eq(1)
  end

  it "uses the adapter's presigned_url for poster URLs" do
    expect(manifest.poster_url).to start_with("memory://course/01/poster.jpg")
  end

  it "signs each segment of a variant" do
    list = manifest.variants.first.playlist
    list.items.each do |item|
      expect(item.segment).to start_with("memory://course/01/0/")
    end
  end
end
