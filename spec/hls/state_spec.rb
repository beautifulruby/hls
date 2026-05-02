# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe HLS::State do
  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  describe ".load" do
    it "returns default data when no state file exists" do
      state = described_class.load(@tmp)
      expect(state.input_digest).to be_nil
      expect(state.renditions).to eq([])
      expect(state.uploads).to eq({})
      expect(state.encoded_at).to be_nil
    end

    it "reads existing state" do
      data = {
        input_digest: "sha256:abc",
        profile: "CourseVideo",
        renditions: [{ width: 1920, height: 1080, bitrate: 5000 }],
        encoded_at: "2026-05-01T20:14:00Z",
        uploads: { "0/0.ts" => { digest: "deadbeef", uploaded_at: "now" } }
      }
      @tmp.join(described_class::FILENAME).write(JSON.pretty_generate(data))

      state = described_class.load(@tmp)
      expect(state.input_digest).to eq("sha256:abc")
      expect(state.profile).to eq("CourseVideo")
      expect(state.renditions.first[:width]).to eq(1920)
    end

    it "raises CorruptError on a malformed state file rather than silently re-encoding" do
      @tmp.join(described_class::FILENAME).write("not json {{{")
      expect {
        described_class.load(@tmp)
      }.to raise_error(HLS::State::CorruptError, /not valid JSON/)
    end
  end

  describe "#encoded?" do
    let(:state) { described_class.load(@tmp) }

    it "is false until #record_encode is called" do
      expect(state.encoded?(input_digest: "sha256:abc")).to be(false)
    end

    it "is true after recording the same digest" do
      state.record_encode(input_digest: "sha256:abc", profile: "X", renditions: [])
      expect(state.encoded?(input_digest: "sha256:abc")).to be(true)
    end

    it "is false when the input digest has changed" do
      state.record_encode(input_digest: "sha256:abc", profile: "X", renditions: [])
      expect(state.encoded?(input_digest: "sha256:def")).to be(false)
    end
  end

  describe "#uploaded?" do
    let(:state) { described_class.load(@tmp) }

    it "is false for an unrecorded key" do
      expect(state.uploaded?(relative_key: "0/0.ts", digest: "abc")).to be(false)
    end

    it "is true for a key whose digest matches" do
      state.record_upload(relative_key: "0/0.ts", digest: "abc")
      expect(state.uploaded?(relative_key: "0/0.ts", digest: "abc")).to be(true)
    end

    it "is false when the digest has changed" do
      state.record_upload(relative_key: "0/0.ts", digest: "abc")
      expect(state.uploaded?(relative_key: "0/0.ts", digest: "def")).to be(false)
    end
  end

  describe "#record_encode" do
    it "resets the uploads map (content has changed)" do
      state = described_class.load(@tmp)
      state.record_upload(relative_key: "0/0.ts", digest: "abc")
      state.record_encode(input_digest: "sha256:new", profile: "X", renditions: [])
      expect(state.uploads).to be_empty
    end
  end

  describe "#save" do
    it "persists state as JSON readable by .load" do
      state = described_class.load(@tmp)
      state.record_encode(input_digest: "sha256:abc", profile: "X", renditions: [{ width: 100, height: 100, bitrate: 100 }])
      state.record_upload(relative_key: "0/0.ts", digest: "ff")
      state.save

      reloaded = described_class.load(@tmp)
      expect(reloaded.input_digest).to eq("sha256:abc")
      expect(reloaded.uploaded?(relative_key: "0/0.ts", digest: "ff")).to be(true)
    end

    it "creates parent directories if they don't exist" do
      nested = @tmp.join("a/b/c")
      state = described_class.load(nested)
      state.record_encode(input_digest: "x", profile: "Y", renditions: [])
      expect { state.save }.not_to raise_error
      expect(nested.join(described_class::FILENAME)).to exist
    end
  end
end
