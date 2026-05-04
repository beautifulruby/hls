# frozen_string_literal: true

require "spec_helper"
require "active_support/isolated_execution_state"
require "active_support/notifications"
require "tmpdir"
require "fileutils"

RSpec.describe HLS::Instrumentation do
  describe ".instrument" do
    it "yields the payload hash" do
      yielded = nil
      described_class.instrument(:test, foo: 1) { |payload| yielded = payload }
      expect(yielded).to eq(foo: 1)
    end

    it "publishes through ActiveSupport::Notifications when defined" do
      events = []
      sub = ActiveSupport::Notifications.subscribe(/\.hls\z/) do |name, _start, _finish, _id, payload|
        events << [name, payload]
      end

      described_class.instrument(:thing, k: "v") { |p| p[:added] = true }

      expect(events).to eq([["thing.hls", { k: "v", added: true }]])
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end
end

RSpec.describe HLS::ApplicationVideo, "instrumentation events" do
  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  let(:input_path) { @tmp.join("input.mp4") }
  let(:input) do
    input_path.write("fake bytes" * 50)
    FakeInput.new(width: 1920, height: 1080, path: input_path.to_s)
  end
  let(:output) { @tmp.join("encoded") }

  let(:bucket) do
    client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    client.stub_responses(:put_object, { etag: '"abc"' })
    Aws::S3::Resource.new(client: client).bucket("test-bucket")
  end

  let(:profile_class) do
    bucket_obj = bucket
    Class.new(described_class).tap do |k|
      k.storage HLS::Storage::S3.new(bucket: bucket_obj, signing_ttl: 3600)
      k.rendition :full, scale: 1.0
    end
  end

  it "publishes upload_retry.hls events with sequential attempt numbers on a flaky bucket" do
    @tmp.join("index.m3u8").write("x")

    attempts = 0
    flaky = Aws::S3::Client.new(stub_responses: true, region: "auto")
    flaky.stub_responses(:put_object, ->(_ctx) {
      attempts += 1
      if attempts < 3
        Aws::S3::Errors::ServiceUnavailable.new(_ctx, "slow")
      else
        { etag: '"x"' }
      end
    })
    bucket = Aws::S3::Resource.new(client: flaky).bucket("test-bucket")

    seen = []
    sub = ActiveSupport::Notifications.subscribe("upload_retry.hls") do |_, _, _, _, payload|
      seen << payload
    end

    HLS::Uploader.new(
      storage: HLS::Storage::S3.new(bucket: bucket, signing_ttl: 3600),
      output: @tmp,
      key_prefix: "v",
      state: HLS::State.load(@tmp),
      max_retries: 5,
      initial_backoff: 0.001,
      concurrency: 1
    ).perform

    expect(seen.map { |p| p[:attempt] }).to eq([1, 2])
    expect(seen.first).to include(
      :key,
      error: "Aws::S3::Errors::ServiceUnavailable"
    )
    expect(seen.first[:key]).to eq("v/index.m3u8")
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  it "publishes encode.hls, verify.hls, upload_object.hls, and process.hls events" do
    profile = profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    allow(profile).to receive(:encode!) do
      HLS::Instrumentation.instrument(:encode, profile: profile.class.name, output: output.to_s) {}
      output.mkpath
      output.join("index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1
        0/index.m3u8
      M3U8
      FileUtils.mkdir_p(output.join("0"))
      output.join("0/index.m3u8").write("#EXTM3U\n#EXTINF:4,\n0.ts\n#EXT-X-ENDLIST\n")
      output.join("0/0.ts").write("seg")
    end

    seen = []
    sub = ActiveSupport::Notifications.subscribe(/\.hls\z/) do |name, _, _, _, payload|
      seen << [name, payload]
    end

    profile.process

    names = seen.map(&:first).uniq
    expect(names).to include("verify.hls", "upload_object.hls", "process.hls")

    process_payload = seen.find { |n, _| n == "process.hls" }.last
    expect(process_payload[:profile]).to eq(profile.class.name)
    expect(process_payload[:uploaded]).to eq(3)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
