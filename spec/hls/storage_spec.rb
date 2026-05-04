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

    it "is safe under concurrent puts and gets across threads" do
      bucket = HLS::Storage::Memory.new(name: "concurrent")
      threads = 8
      writes_per_thread = 50

      writers = threads.times.map do |t|
        Thread.new do
          writes_per_thread.times do |i|
            bucket.object("key-#{t}-#{i}").put(body: "body-#{t}-#{i}")
          end
        end
      end

      readers = threads.times.map do
        Thread.new do
          200.times do
            bucket.keys.each do |key|
              begin
                bucket.object(key).get.body.read
              rescue KeyError
                # racing with not-yet-written keys is fine
              end
            end
          end
        end
      end

      (writers + readers).each(&:join)

      # Every put landed and is readable.
      expect(bucket.keys.size).to eq(threads * writes_per_thread)
      bucket.keys.each do |key|
        expect(bucket.object(key).get.body.read).to start_with("body-")
      end
    end
  end
end

RSpec.describe HLS::ApplicationVideo, "with a duck-typed storage" do
  it "accepts any object that conforms to the storage protocol" do
    storage = HLS::Storage::Memory.new(name: "v")
    klass = Class.new(described_class).tap { |k| k.storage storage }
    expect(klass.storage_or_raise).to be(storage)
  end
end

RSpec.describe HLS::Storage::Memory, "end-to-end with process + manifest" do
  require "tmpdir"
  require "fileutils"

  around { |ex| Dir.mktmpdir { |t| @tmp = Pathname.new(t); ex.run } }

  it "round-trips a profile encode through Memory and back through Manifest" do
    storage = HLS::Storage::Memory.new(name: "v")

    input_path = @tmp.join("input.mp4")
    input_path.write("fake bytes" * 50)
    input = FakeInput.new(width: 1920, height: 1080, path: input_path.to_s)
    output = @tmp.join("encoded")

    klass = Class.new(HLS::ApplicationVideo).tap do |k|
      k.storage storage
      k.rendition :full, scale: 1.0
    end

    profile = klass.new(input: input, output: output, key_prefix: "courses/intro/01")
    allow(profile).to receive(:encode!) do
      output.mkpath
      output.join("index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        0/index.m3u8
      M3U8
      FileUtils.mkdir_p(output.join("0"))
      output.join("0/index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXTINF:4.0,
        0.ts
        #EXT-X-ENDLIST
      M3U8
      output.join("0/0.ts").write("seg-bytes")
    end

    result = profile.process
    expect(result[:uploaded]).to eq(3)

    # Now read the bundle back through Manifest using the same Memory.
    manifest = klass.manifest("courses/intro/01")
    list = manifest.master_playlist
    expect(list.items.size).to eq(1)
    expect(list.items.first.uri).to eq("01/0.m3u8")

    # Variant playlist: signed segment URLs come from the Memory adapter.
    variant = manifest.variants.first
    signed = variant.playlist.items.first.segment
    expect(signed).to start_with("memory://courses/intro/01/0/")

    # And the poster_url adapter call works too.
    expect(manifest.poster_url).to start_with("memory://courses/intro/01/poster.jpg")
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
    described_class.new(storage: bucket, path: "course/01")
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
