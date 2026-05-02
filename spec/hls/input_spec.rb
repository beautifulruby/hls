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
end
