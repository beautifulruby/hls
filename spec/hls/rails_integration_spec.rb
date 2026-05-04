# frozen_string_literal: true

require "spec_helper"
require_relative "../support/dummy_rails_app"
require_relative "../support/fake_input"
require "fileutils"
require "tmpdir"

# Fast Rails integration: boots the dummy Rails app, autoloads
# CourseVideo from spec/dummy/app/videos, then exercises the full
# lifecycle — ActiveJob → process → encode → verify → upload →
# Manifest read with signed URLs. ffmpeg and S3 are both stubbed so
# the whole describe runs in well under a second.
#
# The slow real-ffmpeg counterpart lives in
# spec/integration/rails_pipeline_spec.rb. This file is here to
# guarantee the wiring (Railtie autoload + EncodeJob + state +
# uploader + Manifest) holds together end-to-end without paying the
# ffmpeg cost on every CI run.
RSpec.describe "HLS in a Rails app (fast lifecycle)" do
  before(:all) do
    DummyRailsApp.boot!
    ActiveJob::Base.queue_adapter = :inline
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    require "hls/encode_job"
  end

  let(:put_calls) { [] }
  let(:store)     { {} }

  let(:client) do
    objects = store
    calls   = put_calls
    c = Aws::S3::Client.new(stub_responses: true, region: "auto")
    c.stub_responses(:put_object, ->(context) {
      key   = context.params[:key]
      body  = context.params[:body]
      bytes = body.respond_to?(:read) ? body.read : body.to_s
      objects[key] = bytes
      calls << {
        key: key,
        content_type: context.params[:content_type],
        cache_control: context.params[:cache_control]
      }
      { etag: %("#{Digest::MD5.hexdigest(bytes)}") }
    })
    c.stub_responses(:get_object, ->(context) {
      key = context.params[:key]
      objects.key?(key) ? { body: objects[key] } : "NoSuchKey"
    })
    c
  end

  let(:bucket)     { Aws::S3::Resource.new(client: client).bucket("test-bucket") }
  let(:input_path) { @tmp.join("source.mp4").tap { |p| p.write("placeholder bytes") } }

  around do |example|
    Dir.mktmpdir("hls-rails-fast") do |tmp|
      @tmp = Pathname.new(tmp)
      example.run
    end
  end

  before do
    # Inject the stubbed bucket onto the autoloaded CourseVideo. The
    # dummy ApplicationVideo defines `def self.storage = ...` so a
    # plain writer wouldn't take effect — replace the singleton method
    # with a closure capturing our stub.
    stub_storage = HLS::Storage::S3.new(bucket: bucket, signing_ttl: 3600)
    CourseVideo.singleton_class.alias_method(:_orig_storage, :storage)
    CourseVideo.define_singleton_method(:storage) { stub_storage }

    # Skip ffprobe entirely — return a known-dimension fake.
    allow(HLS::Input).to receive(:new) { |path| FakeInput.new(path: path.to_s) }

    # Skip ffmpeg — drop a fake encoded bundle into the output dir
    # matching CourseVideo's two scaled renditions.
    allow_any_instance_of(CourseVideo).to receive(:encode!) do |profile|
      write_fake_bundle(profile.output)
    end
  end

  after do
    CourseVideo.singleton_class.alias_method(:storage, :_orig_storage)
    CourseVideo.singleton_class.remove_method(:_orig_storage)
  end

  def write_fake_bundle(out)
    out.mkpath
    out.join("index.m3u8").write(<<~M3U8)
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
      0/index.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=960x540
      1/index.m3u8
    M3U8
    [0, 1].each do |idx|
      FileUtils.mkdir_p(out.join(idx.to_s))
      out.join("#{idx}/index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        0.ts
        #EXTINF:4.0,
        1.ts
        #EXTINF:4.0,
        2.ts
        #EXT-X-ENDLIST
      M3U8
      3.times { |s| out.join("#{idx}/#{s}.ts").write("v#{idx}-s#{s}-bytes") }
    end
  end

  describe "EncodeJob lifecycle" do
    it "runs the autoloaded profile through encode → verify → upload" do
      out = @tmp.join("encoded")

      HLS::EncodeJob.perform_now(
        profile: "CourseVideo",
        input: input_path.to_s,
        output: out.to_s,
        key_prefix: "course/intro"
      )

      keys = put_calls.map { |c| c[:key] }
      expect(keys).to include(
        "course/intro/index.m3u8",
        "course/intro/0/index.m3u8",
        "course/intro/0/0.ts",
        "course/intro/1/index.m3u8",
        "course/intro/1/2.ts"
      )
      expect(keys.all? { |k| k.start_with?("course/intro/") }).to be(true)

      m3u8 = put_calls.select { |c| c[:key].end_with?(".m3u8") }
      ts   = put_calls.select { |c| c[:key].end_with?(".ts") }
      expect(m3u8.map { |c| c[:content_type] }).to all(eq("application/vnd.apple.mpegurl"))
      expect(ts.map   { |c| c[:content_type] }).to all(eq("video/MP2T"))
    end

    it "is idempotent — re-running the same job uploads nothing new" do
      args = {
        profile: "CourseVideo",
        input: input_path.to_s,
        output: @tmp.join("encoded").to_s,
        key_prefix: "course/intro"
      }

      HLS::EncodeJob.perform_now(**args)
      first = put_calls.size
      put_calls.clear

      HLS::EncodeJob.perform_now(**args)

      expect(first).to be > 0
      expect(put_calls).to be_empty
    end
  end

  describe "Manifest reads the uploaded bundle" do
    before do
      HLS::EncodeJob.perform_now(
        profile: "CourseVideo",
        input: input_path.to_s,
        output: @tmp.join("encoded").to_s,
        key_prefix: "course/intro"
      )
    end

    it "rewrites variant URIs to <basename>/<index>.m3u8 form" do
      master = CourseVideo.manifest("course/intro").master_playlist
      expect(master.items.size).to eq(2)
      master.items.each { |item| expect(item.uri).to match(%r{\Aintro/\d+\.m3u8\z}) }
    end

    it "produces pre-signed segment URLs in variant playlists" do
      list = CourseVideo.manifest("course/intro").variants.first.playlist
      expect(list.items).not_to be_empty
      list.items.each do |item|
        expect(item.segment).to start_with("https://")
        expect(item.segment).to include("X-Amz-Signature")
      end
    end
  end
end
