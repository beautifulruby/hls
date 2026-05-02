# frozen_string_literal: true

require "spec_helper"
require "hls/testing"
require "tmpdir"

RSpec.describe HLS::Directory do
  include HLS::Testing

  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  before do
    # Seed a small tree of fake video files. The Directory class doesn't
    # probe them — it only matters that the paths exist for #glob.
    %w[a/lecture-01.mp4 a/lecture-02.mp4 b/intro.mp4].each do |relative|
      path = @tmp.join(relative)
      path.parent.mkpath
      path.write("placeholder")
    end
  end

  describe "#glob" do
    it "returns self for chaining" do
      directory = described_class.new(@tmp)
      expect(directory.glob("**/*.mp4")).to equal(directory)
    end
  end

  describe "iteration" do
    let(:directory) { described_class.new(@tmp).glob("**/*.mp4") }

    it "yields one (input, relative_output) pair per matching file" do
      pairs = directory.to_a
      expect(pairs.size).to eq(3)
    end

    it "wraps each path in an HLS::Input" do
      pairs = directory.to_a
      pairs.each do |input, _|
        expect(input).to be_a(HLS::Input)
      end
    end

    it "produces relative output paths with the source extension stripped" do
      pairs = directory.to_a
      output_paths = pairs.map { |_, output| output.to_s }.sort
      expect(output_paths).to eq(%w[a/lecture-01 a/lecture-02 b/intro])
    end

    it "raises when iterated before #glob is set" do
      expect { described_class.new(@tmp).each {} }.to raise_error(ArgumentError, /glob/)
    end
  end

  describe "Enumerable methods" do
    let(:directory) { described_class.new(@tmp).glob("**/*.mp4") }

    it "supports #count" do
      expect(directory.count).to eq(3)
    end

    it "supports #map" do
      relatives = directory.map { |_, output| output.to_s }
      expect(relatives.size).to eq(3)
    end
  end
end
