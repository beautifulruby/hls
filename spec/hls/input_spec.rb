# frozen_string_literal: true

require "spec_helper"
require "hls/testing"
require "tmpdir"

RSpec.describe HLS::Input do
  include HLS::Testing

  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  describe "probing a real video file" do
    let(:input) { described_class.new(generate_test_video(path: @tmp.join("source.mp4"), width: 320, height: 180, duration: 2)) }

    it "reports the video stream's width and height" do
      expect(input.width).to  eq(320)
      expect(input.height).to eq(180)
    end

    it "reports the codec name" do
      expect(input.codec).to eq("h264")
    end

    it "reports a positive duration" do
      expect(input.duration).to be > 0
    end

    it "reports a sensible framerate" do
      # generate_test_video uses rate=30 — testsrc renders 30fps.
      expect(input.framerate).to eq(30)
    end

    it "memoizes the ffprobe result" do
      first = input.json
      second = input.json
      expect(first.equal?(second)).to be(true)
    end

    it "exposes the path as a Pathname" do
      expect(input.path).to be_a(Pathname)
    end
  end

  describe "error handling" do
    it "raises HLS::Error for a missing file" do
      input = described_class.new(@tmp.join("does-not-exist.mp4"))
      expect { input.json }.to raise_error(HLS::Error, /input file not found/)
    end

    it "raises HLS::Error when ffprobe rejects the file" do
      bogus = @tmp.join("not-a-video.mp4")
      bogus.write("definitely not a video")

      input = described_class.new(bogus)
      expect { input.json }.to raise_error(HLS::Error, /ffprobe failed/)
    end

    it "handles paths with spaces and special characters safely" do
      tricky = @tmp.join("file with spaces & 'quotes'.mp4")
      generate_test_video(path: tricky, duration: 1)

      input = described_class.new(tricky)
      expect { input.width }.not_to raise_error
      expect(input.width).to be > 0
    end
  end

  describe "framerate fallback" do
    it "falls back to DEFAULT_FRAMERATE when ffprobe reports nothing usable" do
      input = described_class.allocate
      input.instance_variable_set(:@path, Pathname.new("/tmp/fake"))
      input.instance_variable_set(:@json, {
        streams: [{ width: 100, height: 100, avg_frame_rate: "0/0" }],
        format: {}
      })
      expect(input.framerate).to eq(HLS::Input::DEFAULT_FRAMERATE)
    end

    it "rounds rational framerates correctly" do
      input = described_class.allocate
      input.instance_variable_set(:@path, Pathname.new("/tmp/fake"))
      input.instance_variable_set(:@json, {
        streams: [{ width: 100, height: 100, avg_frame_rate: "30000/1001" }]
      })
      expect(input.framerate).to eq(30)  # 29.97 rounds to 30
    end
  end

  describe "video stream validation" do
    let(:audio_only_path) do
      path = @tmp.join("audio-only.m4a")
      ok = system(
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-c:a", "aac", "-b:a", "64k",
        path.to_s,
        out: File::NULL, err: File::NULL
      )
      raise "couldn't build fixture" unless ok
      path
    end

    it "video? returns true for an actual video file" do
      input = described_class.new(generate_test_video(path: @tmp.join("v.mp4"), duration: 1))
      expect(input.video?).to be(true)
    end

    it "video? returns false for an audio-only file" do
      input = described_class.new(audio_only_path)
      expect(input.video?).to be(false)
    end

    it "validate! raises a descriptive error on audio-only input" do
      input = described_class.new(audio_only_path)
      expect { input.validate! }.to raise_error(HLS::Error, /no video stream/)
    end

    it "validate! returns the input for chaining on a real video" do
      input = described_class.new(generate_test_video(path: @tmp.join("v.mp4"), duration: 1))
      expect(input.validate!).to be(input)
    end

    it "width raises HLS::Error on audio-only input rather than returning nil" do
      input = described_class.new(audio_only_path)
      expect { input.width }.to raise_error(HLS::Error, /no video stream/)
    end
  end
end
