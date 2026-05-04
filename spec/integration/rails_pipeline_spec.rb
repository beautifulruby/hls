# frozen_string_literal: true

require "spec_helper"
require_relative "../support/dummy_rails_app"
require "hls/testing"

# Full-pipeline Rails integration: boots a minimal Rails app, runs a
# real ffmpeg encode through HLS::EncodeJob, uploads to a stubbed S3
# bucket, then verifies the encoded bundle round-trips through
# HLS::Manifest with the right signed URLs.
#
# This is what an HLS-backed Rails app actually does end-to-end. If
# this spec passes, the gem works.

RSpec.describe "HLS in a Rails app", type: :integration do
  include HLS::Testing

  before(:all) do
    DummyRailsApp.boot!
    ActiveJob::Base.queue_adapter = :inline
  end

  around do |example|
    Dir.mktmpdir("hls-rails") do |tmp|
      @tmp = Pathname.new(tmp)
      @input = generate_test_video(path: @tmp.join("source.mp4"), duration: 8)
      example.run
    end
  end

  # Simulate the production flow: an attachment lands → an encode job
  # is enqueued → the job runs the profile → bundle ends up in S3.
  describe "the end-to-end flow" do
    let(:put_calls) { [] }

    let(:bucket) do
      calls = put_calls
      client = Aws::S3::Client.new(stub_responses: true, region: "auto")
      client.stub_responses(:put_object, ->(context) {
        calls << { key: context.params[:key], content_type: context.params[:content_type] }
        { etag: "\"#{calls.size}\"" }
      })
      Aws::S3::Resource.new(client: client).bucket("test-bucket")
    end

    before do
      # Override the autoloaded CourseVideo's storage with the stubbed
      # one. The dummy ApplicationVideo defines storage via
      # `def self.storage = ...` so we redefine the singleton method
      # with a closure to inject our test value (a writer wouldn't
      # take effect — the override would still recompute).
      stub = HLS::Storage::S3.new(bucket: bucket, signing_ttl: 3600)
      CourseVideo.singleton_class.alias_method(:_original_storage, :storage)
      CourseVideo.define_singleton_method(:storage) { stub }
    end

    after do
      CourseVideo.singleton_class.alias_method(:storage, :_original_storage)
      CourseVideo.singleton_class.remove_method(:_original_storage)
    end

    it "encodes, uploads, and produces a bundle the Manifest can serve" do
      output_dir = @tmp.join("encoded")

      silence_ffmpeg do
        HLS::EncodeJob.perform_now(
          profile: "CourseVideo",
          input: @input.to_s,
          output: output_dir.to_s,
          key_prefix: "course/intro"
        )
      end

      # 1. The local bundle on disk is well-formed.
      expect(output_dir).to be_a_valid_hls_bundle.with_variants(2)

      # 2. Every file in the bundle was uploaded under the key_prefix.
      uploaded_keys = put_calls.map { |c| c[:key] }
      expect(uploaded_keys).to include("course/intro/index.m3u8")
      expect(uploaded_keys.all? { |k| k.start_with?("course/intro/") }).to be(true)

      # 3. Content-Types were set per extension.
      m3u8_calls = put_calls.select { |c| c[:key].end_with?(".m3u8") }
      ts_calls   = put_calls.select { |c| c[:key].end_with?(".ts") }
      expect(m3u8_calls.map { |c| c[:content_type] }).to all(eq("application/vnd.apple.mpegurl"))
      expect(ts_calls.map { |c| c[:content_type] }).to all(eq("video/MP2T"))
    end

    it "is idempotent — running the job twice uploads no extra objects" do
      output_dir = @tmp.join("encoded-idem")

      silence_ffmpeg do
        HLS::EncodeJob.perform_now(
          profile: "CourseVideo",
          input: @input.to_s,
          output: output_dir.to_s,
          key_prefix: "course/intro"
        )
        first_count = put_calls.size
        put_calls.clear

        # Run again with the same args; encode should be skipped (state
        # sidecar matches), upload should be a no-op (digests match).
        HLS::EncodeJob.perform_now(
          profile: "CourseVideo",
          input: @input.to_s,
          output: output_dir.to_s,
          key_prefix: "course/intro"
        )
        @second_count = put_calls.size
        @first_count = first_count
      end

      expect(@first_count).to be > 0
      expect(@second_count).to eq(0)
    end
  end

  # Simulate the read side: bundle is in S3, controller asks Manifest
  # for signed URLs, browser hits them.
  describe "Manifest serving the encoded bundle" do
    before do
      bundle_dir = @tmp.join("bundle")

      # Encode the bundle locally first, THEN build the stub bucket
      # from the resulting files. This mirrors production: files already
      # exist in S3 when the controller asks for them.
      encoder_class = Class.new(HLS::ApplicationVideo).tap do |k|
        # Placeholder storage; we don't upload from this class so no
        # network ever happens.
        k.storage HLS::Storage::S3.new(bucket_name: "encode-only")
        k.video_codec "libx264"
        k.audio_codec "aac"
        k.audio_bitrate 64
        k.rendition :high,   scale: 1.0
        k.rendition :medium, scale: 0.5
        k.poster :hero, scale: 1.0
      end

      silence_ffmpeg do
        profile = encoder_class.new(input: HLS::Input.new(@input), output: bundle_dir, key_prefix: "course/intro")
        profile.encode!
        profile.poster!
      end

      # Now build a bucket whose get_object returns the bytes ffmpeg
      # actually wrote.
      stub_objects = {}
      bundle_dir.glob("**/*").each do |path|
        next unless path.file?
        next if path.basename.to_s == HLS::State::FILENAME
        relative = path.relative_path_from(bundle_dir).to_s
        stub_objects["course/intro/#{relative}"] = path.read
      end

      client = Aws::S3::Client.new(stub_responses: true, region: "auto")
      client.stub_responses(:get_object, ->(context) {
        if stub_objects.key?(context.params[:key])
          { body: stub_objects[context.params[:key]] }
        else
          "NoSuchKey"
        end
      })
      bucket = Aws::S3::Resource.new(client: client).bucket("test-bucket")

      reader_class = Class.new(HLS::ApplicationVideo).tap do |k|
        k.storage HLS::Storage::S3.new(bucket: bucket, signing_ttl: 3600)
      end
      stub_const("PipelineTestVideo", reader_class)
    end

    it "returns a master playlist with variant URIs relative to the master URL" do
      manifest = PipelineTestVideo.manifest("course/intro")
      master = manifest.master_playlist

      expect(master.items.size).to eq(2)
      # URIs are basename(path) + variant index — so a player resolving
      # them against /videos/course/intro.m3u8 lands at the right show
      # route.
      master.items.each do |item|
        expect(item.uri).to match(%r{\Aintro/\d+\.m3u8\z})
      end
    end

    it "returns variants whose segment URIs are pre-signed" do
      manifest = PipelineTestVideo.manifest("course/intro")
      variant = manifest.variants.first
      playlist = variant.playlist

      expect(playlist.items).not_to be_empty
      playlist.items.each do |item|
        expect(item.segment).to start_with("https://")
        expect(item.segment).to include("X-Amz-Signature")
      end
    end

    it "returns a signed URL for each declared poster" do
      manifest = PipelineTestVideo.manifest("course/intro")
      url = manifest.poster_url(:hero)
      expect(url).to include("/course/intro/hero.jpg")
      expect(url).to include("X-Amz-Signature")
    end
  end
end
