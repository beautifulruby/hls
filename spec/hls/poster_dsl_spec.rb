# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe HLS::ApplicationVideo, "poster DSL" do
  let(:input)  { FakeInput.new(width: 1920, height: 1080) }
  let(:output) { Pathname.new("tmp/out") }
  let(:profile_class) { Class.new(described_class) }

  describe ".poster" do
    it "accumulates declarations" do
      profile_class.poster :hero, scale: 1.0
      profile_class.poster :card, width: 1280, height: 720

      expect(profile_class.posters.size).to eq(2)
      expect(profile_class.posters.map(&:name)).to eq([:hero, :card])
    end

    it "raises without dimensions or scale" do
      expect { profile_class.poster :broken }
        .to raise_error(ArgumentError, /scale.*width.*height/)
    end

    it "produces files named <name>.jpg" do
      profile_class.poster :thumbnail, width: 320, height: 180
      expect(profile_class.posters.first.filename).to eq("thumbnail.jpg")
    end
  end

  describe "inheritance" do
    let(:parent) do
      Class.new(described_class).tap do |k|
        k.poster :hero, scale: 1.0
      end
    end

    it "subclass inherits parent's posters" do
      child = Class.new(parent)
      expect(child.posters.size).to eq(1)
    end

    it "subclass appends without leaking back to parent" do
      child = Class.new(parent)
      child.poster :card, width: 1280, height: 720

      expect(child.posters.size).to eq(2)
      expect(parent.posters.size).to eq(1)
    end

    it "subclass can reset" do
      child = Class.new(parent)
      child.reset_posters!
      child.poster :tiny, width: 80, height: 45

      expect(child.posters.map(&:name)).to eq([:tiny])
      expect(parent.posters.map(&:name)).to eq([:hero])
    end
  end

  describe "#poster_command" do
    it "produces a single ffmpeg invocation with N outputs for N declarations" do
      profile_class.poster :thumbnail, width: 320, height: 180
      profile_class.poster :card,      width: 1280, height: 720
      profile_class.poster :hero,      scale: 1.0

      profile = profile_class.new(input: input, output: output)
      cmd = profile.poster_command

      expect(cmd[0..3]).to eq(["ffmpeg", "-y", "-i", input.path.to_s])

      # One -frames:v 1 per declaration
      expect(cmd.each_index.count { |i| cmd[i] == "-frames:v" }).to eq(3)

      # Each output filename is at the end of its arg group
      outputs = cmd.each_index.select { |i| cmd[i] == "-frames:v" }.map { |i| cmd[i + 2] }
      expect(outputs).to eq([
        output.join("thumbnail.jpg").to_s,
        output.join("card.jpg").to_s,
        output.join("hero.jpg").to_s
      ])
    end

    it "resolves scale: against the input dimensions" do
      profile_class.poster :half, scale: 0.5
      profile = profile_class.new(input: input, output: output)
      cmd = profile.poster_command

      vf = cmd[cmd.index("-vf") + 1]
      expect(vf).to include("w=960", "h=540")
    end

    it "uses explicit dimensions when provided" do
      profile_class.poster :card, width: 800, height: 450
      profile = profile_class.new(input: input, output: output)
      cmd = profile.poster_command

      vf = cmd[cmd.index("-vf") + 1]
      expect(vf).to include("w=800", "h=450")
    end
  end

  describe "#poster!" do
    around { |ex| Dir.mktmpdir { |t| @tmp = Pathname.new(t); ex.run } }

    it "is a no-op when no posters declared" do
      profile = profile_class.new(input: input, output: @tmp)
      expect(profile).not_to receive(:system)
      profile.poster!
    end

    it "raises HLS::Error when ffmpeg fails" do
      profile_class.poster :hero, scale: 1.0
      profile = profile_class.new(input: input, output: @tmp)
      allow(profile).to receive(:poster_command).and_return(["/usr/bin/false"])

      expect { profile.poster! }.to raise_error(HLS::Error, /ffmpeg failed/)
    end
  end

  describe "#process integration" do
    around { |ex| Dir.mktmpdir { |t| @tmp = Pathname.new(t); ex.run } }

    let(:input_path) { @tmp.join("source.mp4") }
    let(:input) { input_path.write("source"); FakeInput.new(width: 1920, height: 1080, path: input_path.to_s) }

    let(:bucket) do
      client = Aws::S3::Client.new(stub_responses: true, region: "auto")
      Aws::S3::Resource.new(client: client).bucket("test-bucket")
    end

    let(:profile_class) do
      bucket_obj = bucket
      Class.new(described_class).tap do |k|
        k.bucket bucket_obj
        k.rendition :full, scale: 1.0
        k.poster :hero, scale: 1.0
      end
    end

    def write_valid_bundle(output_dir)
      output_dir.mkpath
      output_dir.join("index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1
        0/index.m3u8
      M3U8
      FileUtils.mkdir_p(output_dir.join("0"))
      output_dir.join("0/index.m3u8").write("#EXTM3U\n#EXTINF:4,\n0.ts\n#EXT-X-ENDLIST\n")
      output_dir.join("0/0.ts").write("seg")
    end

    it "calls poster! after encode! when posters are declared" do
      output_dir = @tmp.join("out")
      profile = profile_class.new(input: input, output: output_dir, key_prefix: "v")

      allow(profile).to receive(:encode!) { write_valid_bundle(output_dir) }
      allow(profile).to receive(:poster!).and_wrap_original do |original, *args|
        output_dir.join("hero.jpg").write("fake jpeg")
        original.call(*args)
      end
      allow(profile).to receive(:poster_command).and_return(["/usr/bin/true"])

      profile.process

      expect(profile).to have_received(:poster!).once
    end

    it "skips poster! when no posters declared" do
      profile_class.reset_posters!
      output_dir = @tmp.join("out")
      profile = profile_class.new(input: input, output: output_dir, key_prefix: "v")

      allow(profile).to receive(:encode!) { write_valid_bundle(output_dir) }
      allow(profile).to receive(:poster!)

      profile.process

      expect(profile).not_to have_received(:poster!)
    end
  end
end

RSpec.describe HLS::Manifest, "#poster_url with names" do
  let(:bucket) do
    StubbedBucket.build(name: "videos")
  end

  subject(:manifest) do
    described_class.new(bucket: bucket, path: "course/01", expires_in: 3600)
  end

  it "defaults to poster.jpg for back-compat" do
    expect(manifest.poster_url).to include("/course/01/poster.jpg")
  end

  it "returns a signed URL for a named poster" do
    expect(manifest.poster_url(:thumbnail)).to include("/course/01/thumbnail.jpg")
  end

  it "accepts a string name" do
    expect(manifest.poster_url("hero")).to include("/course/01/hero.jpg")
  end
end
