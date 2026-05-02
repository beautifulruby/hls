# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe HLS::Uploader do
  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  # Builds a stubbed S3 bucket that records every put_object call so
  # tests can assert what was uploaded.
  let(:put_calls) { [] }

  let(:bucket) do
    calls = put_calls
    client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    client.stub_responses(:put_object, ->(context) {
      calls << {
        bucket: context.params[:bucket],
        key: context.params[:key],
        content_type: context.params[:content_type],
        cache_control: context.params[:cache_control]
      }
      { etag: "\"#{calls.size.to_s.rjust(32, '0')}\"" }
    })
    Aws::S3::Resource.new(client: client).bucket("test-bucket")
  end

  let(:state) { HLS::State.load(@tmp) }

  let(:uploader) do
    described_class.new(
      bucket: bucket,
      output: @tmp,
      key_prefix: "videos/foo",
      state: state
    )
  end

  before do
    # Build a fake encoded bundle.
    @tmp.join("index.m3u8").write("#EXTM3U\n#EXT-X-VERSION:6\n0/index.m3u8\n")
    FileUtils.mkdir_p(@tmp.join("0"))
    @tmp.join("0/index.m3u8").write("#EXTM3U\n0.ts\n")
    @tmp.join("0/0.ts").write("\x00\x01" * 100)
    @tmp.join("0/1.ts").write("\x02\x03" * 100)
    @tmp.join("poster.jpg").write("fake image bytes")
  end

  describe "#perform" do
    it "uploads every file in the output directory" do
      result = uploader.perform

      keys = put_calls.map { |c| c[:key] }
      expect(keys).to contain_exactly(
        "videos/foo/index.m3u8",
        "videos/foo/0/index.m3u8",
        "videos/foo/0/0.ts",
        "videos/foo/0/1.ts",
        "videos/foo/poster.jpg"
      )
      expect(result[:uploaded]).to eq(5)
      expect(result[:skipped]).to eq(0)
    end

    it "skips the .hls-state.json sidecar from upload" do
      state.record_upload(relative_key: "ignored", digest: "x") # forces sidecar to exist
      state.save

      uploader.perform

      keys = put_calls.map { |c| c[:key] }
      expect(keys).not_to include(/hls-state/)
    end

    it "sets correct Content-Type per extension" do
      uploader.perform

      ts_call = put_calls.find { |c| c[:key].end_with?("0.ts") }
      m3u8_call = put_calls.find { |c| c[:key].end_with?("index.m3u8") }
      jpg_call = put_calls.find { |c| c[:key].end_with?("poster.jpg") }

      expect(ts_call[:content_type]).to eq("video/MP2T")
      expect(m3u8_call[:content_type]).to eq("application/vnd.apple.mpegurl")
      expect(jpg_call[:content_type]).to eq("image/jpeg")
    end

    it "sets immutable cache-control on segments and posters" do
      uploader.perform

      ts_call = put_calls.find { |c| c[:key].end_with?("0.ts") }
      jpg_call = put_calls.find { |c| c[:key].end_with?("poster.jpg") }

      expect(ts_call[:cache_control]).to include("max-age=31536000", "immutable")
      expect(jpg_call[:cache_control]).to include("max-age=31536000", "immutable")
    end

    it "sets a short max-age on playlists so a superseding bundle can take effect quickly" do
      # VOD playlists themselves are immutable (segments don't change after
      # encode), but we want them cacheable at the CDN with a much shorter
      # window than the segments so a redeploy of the bundle isn't blocked
      # by stale playlists.
      uploader.perform

      m3u8_call = put_calls.find { |c| c[:key].end_with?("index.m3u8") }
      expect(m3u8_call[:cache_control]).to include("max-age=")
      expect(m3u8_call[:cache_control]).to include("public")
      max_age = m3u8_call[:cache_control][/max-age=(\d+)/, 1].to_i
      expect(max_age).to be < 86400  # well under a day
    end

    it "is idempotent — re-running uploads zero files" do
      uploader.perform
      put_calls.clear

      result = uploader.perform
      expect(put_calls).to be_empty
      expect(result[:uploaded]).to eq(0)
      expect(result[:skipped]).to eq(5)
    end

    it "resumes from a partial state — only uploads missing keys" do
      # Pre-record one file as already uploaded by computing its digest and writing state.
      digest = Digest::MD5.file(@tmp.join("0/0.ts")).hexdigest
      state.record_upload(relative_key: "0/0.ts", digest: digest)
      state.save

      result = uploader.perform

      expect(result[:uploaded]).to eq(4)
      expect(result[:skipped]).to eq(1)
      expect(put_calls.map { |c| c[:key] }).not_to include("videos/foo/0/0.ts")
    end

    it "re-uploads when local file content differs from recorded digest" do
      # Pre-record with a wrong digest to simulate file having been changed
      # since last upload.
      state.record_upload(relative_key: "0/0.ts", digest: "stale-digest")
      state.save

      result = uploader.perform

      expect(result[:uploaded]).to eq(5) # all 5 files uploaded
      expect(put_calls.map { |c| c[:key] }).to include("videos/foo/0/0.ts")
    end

    it "writes state.json after each successful upload" do
      uploader.perform

      reloaded = HLS::State.load(@tmp)
      expect(reloaded.uploads.size).to eq(5)
    end

    it "records the etag returned by S3 for each upload" do
      uploader.perform

      reloaded = HLS::State.load(@tmp)
      reloaded.uploads.each_value do |entry|
        expect(entry[:etag]).to be_a(String)
        expect(entry[:etag]).not_to be_empty
      end
    end

    it "handles an empty key_prefix without producing leading slashes" do
      uploader = described_class.new(
        bucket: bucket,
        output: @tmp,
        key_prefix: "",
        state: state
      )
      uploader.perform

      keys = put_calls.map { |c| c[:key] }
      expect(keys.all? { |k| !k.start_with?("/") }).to be(true)
      expect(keys).to include("index.m3u8", "0/0.ts")
    end

    it "strips leading and trailing slashes from key_prefix" do
      uploader = described_class.new(
        bucket: bucket,
        output: @tmp,
        key_prefix: "/videos/foo/",
        state: state
      )
      uploader.perform

      keys = put_calls.map { |c| c[:key] }
      expect(keys).to include("videos/foo/index.m3u8")
      expect(keys.none? { |k| k.start_with?("/") || k.include?("//") }).to be(true)
    end
  end
end
