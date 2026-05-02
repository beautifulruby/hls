# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Specs for HLS::ApplicationVideo#process — the encode + upload
# orchestration. These don't actually run ffmpeg; they stub `encode!`
# to drop a fake bundle into the output dir and then verify upload
# behavior + idempotency end-to-end.

RSpec.describe HLS::ApplicationVideo, "#process orchestration" do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = Pathname.new(tmp)
      example.run
    end
  end

  let(:put_calls) { [] }

  let(:bucket) do
    calls = put_calls
    client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    client.stub_responses(:put_object, ->(context) {
      calls << context.params
      { etag: "\"#{calls.size}\"" }
    })
    Aws::S3::Resource.new(client: client).bucket("test-bucket")
  end

  # Real input file with known content so we can compute a real digest.
  let(:input_path) { @tmp.join("input.mp4") }
  let(:input) do
    input_path.write("fake video bytes" * 100)
    FakeInput.new(width: 1920, height: 1080, path: input_path.to_s)
  end

  let(:output) { @tmp.join("encoded") }

  let(:profile_class) do
    bucket_obj = bucket
    Class.new(described_class).tap do |k|
      k.bucket bucket_obj
      k.rendition :full, scale: 1.0
    end
  end

  # Drop a fake encoded bundle into output instead of actually running
  # ffmpeg. Returns the profile instance.
  def stub_encode_with_files(profile)
    allow(profile).to receive(:encode!) do
      output.mkpath
      output.join("index.m3u8").write("#EXTM3U\n0/index.m3u8\n")
      FileUtils.mkdir_p(output.join("0"))
      output.join("0/index.m3u8").write("#EXTM3U\n0.ts\n")
      output.join("0/0.ts").write("\x00\x01" * 100)
    end
    profile
  end

  it "runs encode then upload on the first invocation" do
    profile = stub_encode_with_files(
      profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    )

    profile.process

    expect(profile).to have_received(:encode!).once
    expect(put_calls.size).to eq(3)
  end

  it "skips encode on the second invocation when input hasn't changed" do
    p1 = stub_encode_with_files(
      profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    )
    p1.process
    encode1_call_count = RSpec::Mocks.space.proxy_for(p1).messages_arg_list.size rescue 1

    # Second invocation, separate instance, same input.
    p2 = profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    allow(p2).to receive(:encode!) # don't overwrite, just spy
    put_calls.clear

    p2.process

    expect(p2).not_to have_received(:encode!)
    expect(put_calls).to be_empty
  end

  it "re-encodes when the input digest changes" do
    p1 = stub_encode_with_files(
      profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    )
    p1.process

    # Mutate input — different bytes → different digest.
    input_path.write("totally different content" * 50)
    input2 = FakeInput.new(width: 1920, height: 1080, path: input_path.to_s)

    p2 = profile_class.new(input: input2, output: output, key_prefix: "videos/foo")
    encoded = false
    allow(p2).to receive(:encode!) do
      encoded = true
      output.join("0/0.ts").write("new segment bytes" * 100)
    end
    put_calls.clear

    p2.process

    expect(encoded).to be(true)
    expect(put_calls).not_to be_empty
  end

  it "re-encodes when state says encoded but the master playlist file is missing" do
    p1 = stub_encode_with_files(
      profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    )
    p1.process

    # Simulate the output dir being wiped (e.g., ephemeral worker
    # restart) but state.json surviving in some other tracking system.
    # Without the file-existence check in `encoded?`, we'd happily skip
    # the encode and try to upload nothing.
    output.children.each { |c| FileUtils.rm_rf(c) unless c.basename.to_s == HLS::State::FILENAME }
    expect(output.join(HLS::ApplicationVideo::PLAYLIST)).not_to exist

    p2 = profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    re_encoded = false
    allow(p2).to receive(:encode!) do
      re_encoded = true
      output.mkpath
      output.join("index.m3u8").write("#EXTM3U\n0/index.m3u8\n")
      FileUtils.mkdir_p(output.join("0"))
      output.join("0/index.m3u8").write("#EXTM3U\n0.ts\n")
      output.join("0/0.ts").write("seg")
    end

    p2.process

    expect(re_encoded).to be(true)
  end

  it "key_prefix defaults to the output directory's basename" do
    output_named = @tmp.join("my-video-id")
    profile = stub_encode_with_files(
      profile_class.new(input: input, output: output_named)
    )

    profile.process

    keys = put_calls.map { |c| c[:key] }
    expect(keys.all? { |k| k.start_with?("my-video-id/") }).to be(true)
  end

  it "computes input_digest as a stable sha256" do
    profile = profile_class.new(input: input, output: output)
    digest1 = profile.input_digest
    digest2 = profile_class.new(input: input, output: output).input_digest

    expect(digest1).to start_with("sha256:")
    expect(digest1).to eq(digest2)
  end
end

RSpec.describe HLS::ApplicationVideo, "#encode!" do
  let(:input)  { FakeInput.new(width: 1920, height: 1080, path: "/tmp/none.mp4") }

  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  let(:profile_class) do
    Class.new(described_class).tap { |k| k.rendition :full, scale: 1.0 }
  end

  it "raises HLS::Error when ffmpeg fails" do
    profile = profile_class.new(input: input, output: @tmp.join("out"))
    # The default ffmpeg invocation against a non-existent file will fail.
    # We don't want to actually shell out — replace the command with a
    # guaranteed-failing /usr/bin/false.
    allow(profile).to receive(:command).and_return(["/usr/bin/false"])

    expect { profile.encode! }.to raise_error(HLS::Error, /ffmpeg failed/)
  end

  it "creates the output directory before invoking ffmpeg" do
    out = @tmp.join("nested/dir")
    profile = profile_class.new(input: input, output: out)
    allow(profile).to receive(:command).and_return(["/usr/bin/true"])

    expect { profile.encode! }.not_to raise_error
    expect(out).to exist
  end
end
