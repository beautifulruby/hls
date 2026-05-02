# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe HLS::ApplicationVideo do
  let(:input)  { FakeInput.new(width: 1920, height: 1080) }
  let(:output) { Pathname.new("tmp/out") }

  # Each test gets a fresh anonymous subclass so DSL state doesn't leak.
  let(:profile_class) { Class.new(described_class) }

  describe "the rendition DSL" do
    it "accepts an explicit rendition with width/height/bitrate" do
      profile_class.rendition width: 1280, height: 720, bitrate: 1500

      profile = profile_class.new(input: input, output: output)

      expect(profile.renditions).to eq([
        HLS::ApplicationVideo::Rendition.new(width: 1280, height: 720, bitrate: 1500)
      ])
    end

    it "accepts a scaled rendition with scale: and resolves it against the input" do
      profile_class.bits_per_pixel :screencast # 3
      profile_class.rendition :full, scale: 1.0

      profile = profile_class.new(input: input, output: output)

      # 1920 * 1080 * 3 / 1000 = 6220.8 → ceil to nearest 100 = 6300
      expect(profile.renditions).to eq([
        HLS::ApplicationVideo::Rendition.new(width: 1920, height: 1080, bitrate: 6300)
      ])
    end

    it "caps scaled bitrate at max_bitrate_kbps" do
      profile_class.bits_per_pixel :motion # 6
      profile_class.max_bitrate_kbps 5_000
      profile_class.rendition :full, scale: 1.0

      profile = profile_class.new(input: input, output: output)

      expect(profile.renditions.first.bitrate).to eq(5_000)
    end

    it "raises when neither scale nor explicit dims are provided" do
      expect {
        profile_class.rendition :half
      }.to raise_error(ArgumentError, /scale.*width.*height.*bitrate/)
    end
  end

  describe "rendition inheritance" do
    let(:parent) do
      Class.new(described_class).tap do |k|
        k.rendition :a, scale: 1.0
        k.rendition :b, scale: 0.5
      end
    end

    it "subclass inherits parent declarations" do
      child = Class.new(parent)
      expect(child.renditions.size).to eq(2)
    end

    it "subclass appends to parent declarations without leaking back" do
      child = Class.new(parent)
      child.rendition :c, scale: 0.25

      expect(child.renditions.size).to eq(3)
      expect(parent.renditions.size).to eq(2)
    end

    it "subclass can reset and start fresh" do
      child = Class.new(parent)
      child.reset_renditions!
      child.rendition width: 640, height: 360, bitrate: 800

      expect(child.renditions.size).to eq(1)
      expect(child.renditions.first.width).to eq(640)
      expect(parent.renditions.size).to eq(2)
    end
  end

  describe "class settings" do
    it "stores and reads bucket" do
      profile_class.bucket "videos-prod"
      expect(profile_class.bucket).to eq("videos-prod")
    end

    it "uses sensible defaults" do
      expect(profile_class.signing_ttl).to eq(3600)
      expect(profile_class.segment_duration).to eq(4)
      expect(profile_class.audio_codec).to eq("aac")
      expect(profile_class.audio_bitrate).to eq(128)
      expect(profile_class.video_codec).to eq(:h264)
      expect(profile_class.max_bitrate_kbps).to eq(15_000)
    end

    it "inherits settings from parent class" do
      parent = Class.new(described_class) { bucket "from-parent" }
      child = Class.new(parent)

      expect(child.bucket).to eq("from-parent")
    end

    it "child overrides parent without mutating parent" do
      parent = Class.new(described_class) { bucket "parent-bucket" }
      child  = Class.new(parent) { bucket "child-bucket" }

      expect(child.bucket).to  eq("child-bucket")
      expect(parent.bucket).to eq("parent-bucket")
    end

    it "coerces bits_per_pixel symbols to integers" do
      profile_class.bits_per_pixel :motion
      expect(profile_class.bits_per_pixel).to eq(6)
    end

    it "accepts an integer bits_per_pixel directly" do
      profile_class.bits_per_pixel 5
      expect(profile_class.bits_per_pixel).to eq(5)
    end

    it "raises on unknown bits_per_pixel symbol" do
      expect { profile_class.bits_per_pixel :galaxy_brain }.to raise_error(KeyError)
    end
  end

  describe "#downscaleable_renditions" do
    before do
      profile_class.rendition width: 3840, height: 2160, bitrate: 15_000  # 4K
      profile_class.rendition width: 1920, height: 1080, bitrate: 5_000   # 1080p
      profile_class.rendition width: 1280, height: 720,  bitrate: 2_500   # 720p
    end

    it "filters out renditions wider than the input (no upscaling)" do
      profile = profile_class.new(input: input, output: output) # 1920 wide

      widths = profile.downscaleable_renditions.map(&:width)
      expect(widths).to eq([1920, 1280])
    end
  end

  describe "#exist?" do
    it "is true when the master playlist file exists in the output dir" do
      Dir.mktmpdir do |tmp|
        path = Pathname.new(tmp)
        FileUtils.touch path.join(HLS::ApplicationVideo::PLAYLIST)

        profile_class.rendition :full, scale: 1.0
        profile = profile_class.new(input: input, output: path)

        expect(profile.exist?).to be(true)
      end
    end

    it "is false when the master playlist is missing" do
      Dir.mktmpdir do |tmp|
        profile_class.rendition :full, scale: 1.0
        profile = profile_class.new(input: input, output: Pathname.new(tmp))

        expect(profile.exist?).to be(false)
      end
    end
  end

  describe "#command" do
    let(:profile_class) do
      Class.new(described_class).tap do |k|
        k.bits_per_pixel :screencast
        k.rendition :full,   scale: 1.0
        k.rendition :medium, scale: 0.5
        k.rendition :small,  scale: 0.25
      end
    end

    let(:profile) { profile_class.new(input: input, output: output) }

    it "begins with ffmpeg invocation and the input file" do
      cmd = profile.command
      expect(cmd[0..3]).to eq(["ffmpeg", "-y", "-i", input.path.to_s])
    end

    it "uses the configured segment duration in -hls_time" do
      profile_class.segment_duration 6
      cmd = profile.command
      i = cmd.index("-hls_time")
      expect(cmd[i + 1]).to eq("6")
    end

    it "uses the configured video codec" do
      profile_class.video_codec "libx264"
      cmd = profile.command
      # First "-c:v:0" sets the encoder for rendition 0.
      i = cmd.index("-c:v:0")
      expect(cmd[i + 1]).to eq("libx264")
    end

    it "emits libx264-specific options when libx264 is selected" do
      profile_class.video_codec "libx264"
      cmd = profile.command
      expect(cmd).to include("-preset:v:0", "slow")
      expect(cmd).to include("-tune:v:0", "animation")
    end

    it "omits libx264 options for h264_videotoolbox" do
      profile_class.video_codec "h264_videotoolbox"
      cmd = profile.command
      expect(cmd).not_to include("-preset:v:0")
      expect(cmd).not_to include("-tune:v:0")
    end

    it "writes one var_stream_map entry per downscaleable rendition" do
      cmd = profile.command
      i = cmd.index("-var_stream_map")
      expect(cmd[i + 1]).to eq("v:0,a:0 v:1,a:1 v:2,a:2")
    end

    it "produces a complete master playlist filename" do
      cmd = profile.command
      i = cmd.index("-master_pl_name")
      expect(cmd[i + 1]).to eq("index.m3u8")
    end

    it "emits a video map for each downscaleable rendition" do
      cmd = profile.command
      maps = cmd.each_with_index.select { |a, _| a == "-map" }.map { |_, i| cmd[i + 1] }
      expect(maps).to include("[v1out]", "[v2out]", "[v3out]", "a:0")
    end

    it "produces the expected bitrate ladder for screencast content at 1920x1080" do
      bitrates = profile.renditions.map(&:bitrate)
      # Full:    1920*1080*3/1000 = 6220.8 → 6300
      # Medium:   960* 540*3/1000 = 1555.2 → 1600
      # Small:    480* 270*3/1000 =  388.8 →  400
      expect(bitrates).to eq([6300, 1600, 400])
    end

    it "scales GOP/keyint with framerate × segment_duration" do
      profile_class.segment_duration 4
      input_30fps = FakeInput.new(width: 1920, height: 1080, framerate: 30)
      profile = profile_class.new(input: input_30fps, output: output)

      cmd = profile.command
      # GOP for the first rendition: 30 * 4 = 120
      i = cmd.index("-g")
      expect(cmd[i + 1]).to eq("120")
      j = cmd.index("-keyint_min")
      expect(cmd[j + 1]).to eq("120")
    end

    it "uses a different GOP for a different segment_duration" do
      profile_class.segment_duration 6
      input_30fps = FakeInput.new(width: 1920, height: 1080, framerate: 30)
      profile = profile_class.new(input: input_30fps, output: output)

      cmd = profile.command
      i = cmd.index("-g")
      # 30fps × 6s = 180
      expect(cmd[i + 1]).to eq("180")
    end

    it "uses a different GOP for a different framerate" do
      profile_class.segment_duration 4
      input_60fps = FakeInput.new(width: 1920, height: 1080, framerate: 60)
      profile = profile_class.new(input: input_60fps, output: output)

      cmd = profile.command
      i = cmd.index("-g")
      # 60fps × 4s = 240
      expect(cmd[i + 1]).to eq("240")
    end
  end

  describe "command equivalence with the legacy Scalable shape" do
    # This test pins the ffmpeg arg list against the output we ship for
    # a typical screencast configuration. The GOP value (120) is
    # intentionally different from the legacy's hardcoded 180: it now
    # scales as framerate × segment_duration (30fps × 4s = 120) so each
    # HLS segment starts on a keyframe.
    let(:profile_class) do
      Class.new(described_class).tap do |k|
        k.bits_per_pixel :screencast
        k.max_bitrate_kbps 15_000
        k.video_codec "h264_videotoolbox"
        k.rendition :full,   scale: 1.0
        k.rendition :medium, scale: 0.5
        k.rendition :small,  scale: 0.25
      end
    end

    let(:expected) do
      [
        "ffmpeg", "-y",
        "-i", "/tmp/fake.mp4",
        "-filter_complex",
        "[0:v]split=3[v1][v2][v3]; " \
        "[v1]scale='if(gt(iw,1920),1920,iw)':'if(gt(iw,1920),-2,ih)'[v1out]; " \
        "[v2]scale='if(gt(iw,960),960,iw)':'if(gt(iw,960),-2,ih)'[v2out]; " \
        "[v3]scale='if(gt(iw,480),480,iw)':'if(gt(iw,480),-2,ih)'[v3out]",
        "-map", "[v1out]",
        "-c:v:0", "h264_videotoolbox",
        "-b:v:0", "6300k",
        "-maxrate:v:0", "6930k",
        "-bufsize:v:0", "12600k",
        "-g", "120", "-keyint_min", "120", "-sc_threshold", "0",
        "-map", "[v2out]",
        "-c:v:1", "h264_videotoolbox",
        "-b:v:1", "1600k",
        "-maxrate:v:1", "1760k",
        "-bufsize:v:1", "3200k",
        "-g", "120", "-keyint_min", "120", "-sc_threshold", "0",
        "-map", "[v3out]",
        "-c:v:2", "h264_videotoolbox",
        "-b:v:2", "400k",
        "-maxrate:v:2", "440k",
        "-bufsize:v:2", "800k",
        "-g", "120", "-keyint_min", "120", "-sc_threshold", "0",
        "-map", "a:0", "-c:a:0", "aac", "-b:a:0", "128k", "-ac", "2",
        "-map", "a:0", "-c:a:1", "aac", "-b:a:1", "128k", "-ac", "2",
        "-map", "a:0", "-c:a:2", "aac", "-b:a:2", "128k", "-ac", "2",
        "-f", "hls",
        "-var_stream_map", "v:0,a:0 v:1,a:1 v:2,a:2",
        "-master_pl_name", "index.m3u8",
        "-hls_time", "4",
        "-hls_playlist_type", "vod",
        "-hls_segment_filename", "tmp/out/%v/%d.ts",
        "tmp/out/%v/index.m3u8"
      ]
    end

    it "matches the expected ffmpeg argument vector exactly" do
      profile = profile_class.new(input: input, output: output)
      expect(profile.command).to eq(expected)
    end
  end
end
