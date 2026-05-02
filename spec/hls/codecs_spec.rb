# frozen_string_literal: true

require "spec_helper"

RSpec.describe HLS::Codecs do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".resolve" do
    it "passes through an explicit string encoder name" do
      expect(described_class.resolve("libx264")).to eq("libx264")
    end

    it "passes through an explicit encoder name including hardware-specific ones" do
      expect(described_class.resolve("h264_nvenc")).to eq("h264_nvenc")
    end

    it "maps a known codec symbol to its ffmpeg encoder" do
      expect(described_class.resolve(:libx264)).to eq("libx264")
      expect(described_class.resolve(:nvenc)).to eq("h264_nvenc")
      expect(described_class.resolve(:videotoolbox)).to eq("h264_videotoolbox")
    end

    it "raises on an unknown codec symbol" do
      expect { described_class.resolve(:bogus) }.to raise_error(HLS::Codecs::UnknownEncoder)
    end

    it "raises on an unsupported value type" do
      expect { described_class.resolve(123) }.to raise_error(ArgumentError)
    end

    context "with :h264 logical codec" do
      it "picks h264_videotoolbox when on darwin and it's available" do
        allow(described_class).to receive(:platform).and_return(:darwin)
        allow(described_class).to receive(:available_encoders).and_return(
          Set.new(%w[libx264 h264_videotoolbox aac])
        )

        expect(described_class.resolve(:h264)).to eq("h264_videotoolbox")
      end

      it "falls back to libx264 on darwin when videotoolbox is missing" do
        allow(described_class).to receive(:platform).and_return(:darwin)
        allow(described_class).to receive(:available_encoders).and_return(
          Set.new(%w[libx264 aac])
        )

        expect(described_class.resolve(:h264)).to eq("libx264")
      end

      it "prefers nvenc on linux when available" do
        allow(described_class).to receive(:platform).and_return(:linux)
        allow(described_class).to receive(:available_encoders).and_return(
          Set.new(%w[libx264 h264_nvenc aac])
        )

        expect(described_class.resolve(:h264)).to eq("h264_nvenc")
      end

      it "falls back to qsv before libx264 on linux" do
        allow(described_class).to receive(:platform).and_return(:linux)
        allow(described_class).to receive(:available_encoders).and_return(
          Set.new(%w[libx264 h264_qsv aac])
        )

        expect(described_class.resolve(:h264)).to eq("h264_qsv")
      end

      it "lands on libx264 on linux without GPU encoders" do
        allow(described_class).to receive(:platform).and_return(:linux)
        allow(described_class).to receive(:available_encoders).and_return(
          Set.new(%w[libx264 aac])
        )

        expect(described_class.resolve(:h264)).to eq("libx264")
      end

      it "lands on libx264 on unknown platforms" do
        allow(described_class).to receive(:platform).and_return(:freebsd)
        allow(described_class).to receive(:available_encoders).and_return(
          Set.new(%w[libx264])
        )

        expect(described_class.resolve(:h264)).to eq("libx264")
      end
    end
  end

  describe ".available_encoders" do
    it "returns a Set of encoder names parsed from ffmpeg" do
      # Real ffmpeg call. CI must have ffmpeg installed.
      encoders = described_class.available_encoders
      expect(encoders).to be_a(Set)
      expect(encoders).to include("libx264") if described_class.platform != :unknown
      expect(encoders).to include("aac")
    end

    it "caches the result" do
      first  = described_class.available_encoders
      second = described_class.available_encoders
      expect(first.equal?(second)).to be(true)
    end
  end
end

RSpec.describe HLS::ApplicationVideo, "video_codec resolution" do
  let(:input)  { FakeInput.new(width: 1920, height: 1080) }
  let(:output) { Pathname.new("tmp/out") }

  before { HLS::Codecs.reset! }
  after  { HLS::Codecs.reset! }

  it "passes the resolved encoder name through to the ffmpeg command" do
    allow(HLS::Codecs).to receive(:resolve).with(:h264).and_return("libx264")

    profile_class = Class.new(described_class).tap do |k|
      k.video_codec :h264
      k.rendition :full, scale: 1.0
    end

    profile = profile_class.new(input: input, output: output)
    cmd = profile.command

    i = cmd.index("-c:v:0")
    expect(cmd[i + 1]).to eq("libx264")
    expect(cmd).to include("-preset:v:0", "slow") # libx264-specific options applied
  end

  it "uses an explicit string codec without invoking the resolver-magic path" do
    profile_class = Class.new(described_class).tap do |k|
      k.video_codec "h264_videotoolbox"
      k.rendition :full, scale: 1.0
    end

    profile = profile_class.new(input: input, output: output)
    cmd = profile.command
    i = cmd.index("-c:v:0")
    expect(cmd[i + 1]).to eq("h264_videotoolbox")
  end
end
