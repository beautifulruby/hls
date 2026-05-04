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
      k.storage HLS::Storage::S3.new(bucket: bucket_obj, signing_ttl: 3600)
      k.rendition :full, scale: 1.0
    end
  end

  # Drop a fake encoded bundle into output instead of actually running
  # ffmpeg. Returns the profile instance.
  def stub_encode_with_files(profile)
    out = profile.output
    allow(profile).to receive(:encode!) do
      out.mkpath
      out.join("index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        0/index.m3u8
      M3U8
      FileUtils.mkdir_p(out.join("0"))
      out.join("0/index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXTINF:4.0,
        0.ts
        #EXT-X-ENDLIST
      M3U8
      out.join("0/0.ts").write("\x00\x01" * 100)
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
      output.join("index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        0/index.m3u8
      M3U8
      FileUtils.mkdir_p(output.join("0"))
      output.join("0/index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXTINF:4.0,
        0.ts
        #EXT-X-ENDLIST
      M3U8
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

  it "does not write state.json when verify_encode! fails (ordering invariant)" do
    profile = profile_class.new(input: input, output: output, key_prefix: "videos/foo")
    # Stub encode! to write a *broken* bundle: master playlist refers to
    # a variant that doesn't exist on disk. verify_encode! must catch
    # this and raise BEFORE state.save runs.
    allow(profile).to receive(:encode!) do
      output.mkpath
      output.join("index.m3u8").write(<<~M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        0/index.m3u8
      M3U8
      # Don't write the variant playlist — verify should catch this.
    end

    expect { profile.process }.to raise_error(HLS::Error, /variant playlist missing/)

    state_file = output.join(HLS::State::FILENAME)
    if state_file.exist?
      data = JSON.parse(state_file.read, symbolize_names: true)
      # encoded_at should still be nil — we never recorded a successful encode.
      expect(data[:encoded_at]).to be_nil
      expect(data[:input_digest]).to be_nil
    end
    # Critically: a re-run with the same input must re-attempt encode,
    # not skip to upload of nothing.
    expect(profile).to receive(:encode!).and_call_original
    expect { profile.process }.to raise_error(HLS::Error)
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

  it "includes stderr from the failing process in the error message" do
    profile = profile_class.new(input: input, output: @tmp.join("out"))
    # Use sh to write a known string to stderr and exit non-zero.
    allow(profile).to receive(:command).and_return([
      "sh", "-c", "echo 'something exploded in encoder' >&2; exit 1"
    ])

    expect { profile.encode! }.to raise_error(HLS::Error, /something exploded in encoder/)
  end

  it "truncates very long stderr to a tail" do
    profile = profile_class.new(input: input, output: @tmp.join("out"))
    # 5000 chars to stderr — should be truncated to a tail with leading "...".
    allow(profile).to receive(:command).and_return([
      "sh", "-c", "head -c 5000 /dev/zero | tr '\\0' 'X' >&2; exit 1"
    ])

    expect { profile.encode! }.to raise_error(HLS::Error) do |err|
      expect(err.message).to include("...")
      expect(err.message.length).to be < 5000
    end
  end

  it "creates the output directory before invoking ffmpeg" do
    out = @tmp.join("nested/dir")
    profile = profile_class.new(input: input, output: out)
    allow(profile).to receive(:command).and_return(["/usr/bin/true"])

    expect { profile.encode! }.not_to raise_error
    expect(out).to exist
  end

  describe "ffmpeg_timeout" do
    let(:profile_class) do
      Class.new(described_class).tap do |k|
        k.rendition :full, scale: 1.0
        k.ffmpeg_timeout 0.3
      end
    end

    it "kills a runaway ffmpeg and raises a timeout error" do
      profile = profile_class.new(input: input, output: @tmp.join("out"))
      allow(profile).to receive(:command).and_return(["sleep", "30"])

      start = Time.now
      expect {
        profile.encode!
      }.to raise_error(HLS::Error, /timed out after 0\.3s/)

      # We don't need a tight assertion — just that we didn't actually
      # wait the full 30 seconds.
      expect(Time.now - start).to be < 5
    end

    it "does not interfere with a fast process" do
      profile = profile_class.new(input: input, output: @tmp.join("out"))
      allow(profile).to receive(:command).and_return(["/usr/bin/true"])
      expect { profile.encode! }.not_to raise_error
    end
  end
end

RSpec.describe HLS::ApplicationVideo, "#verify_encode!" do
  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  let(:input) { FakeInput.new(width: 1920, height: 1080, path: "/tmp/none.mp4") }
  let(:output) { @tmp.join("out") }
  let(:profile_class) do
    Class.new(described_class).tap { |k| k.rendition :full, scale: 1.0 }
  end

  def write_valid_bundle
    output.mkpath
    output.join("index.m3u8").write(<<~M3U8)
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=1000000
      0/index.m3u8
    M3U8
    FileUtils.mkdir_p(output.join("0"))
    output.join("0/index.m3u8").write(<<~M3U8)
      #EXTM3U
      #EXTINF:4.0,
      0.ts
      #EXT-X-ENDLIST
    M3U8
    output.join("0/0.ts").write("\x00\x01" * 100)
  end

  it "passes for a well-formed bundle" do
    profile = profile_class.new(input: input, output: output)
    write_valid_bundle
    expect { profile.verify_encode! }.not_to raise_error
  end

  it "raises when the master playlist is missing" do
    profile = profile_class.new(input: input, output: output)
    output.mkpath
    expect { profile.verify_encode! }.to raise_error(HLS::Error, /no master playlist/)
  end

  it "raises when a variant playlist is missing on disk" do
    profile = profile_class.new(input: input, output: output)
    output.mkpath
    output.join("index.m3u8").write("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n0/index.m3u8\n")
    expect { profile.verify_encode! }.to raise_error(HLS::Error, /variant playlist missing: 0\/index\.m3u8/)
  end

  it "raises when a segment is missing" do
    profile = profile_class.new(input: input, output: output)
    write_valid_bundle
    FileUtils.rm(output.join("0/0.ts"))
    expect { profile.verify_encode! }.to raise_error(HLS::Error, /segment missing or empty/)
  end

  it "raises when a segment is empty (zero bytes)" do
    profile = profile_class.new(input: input, output: output)
    write_valid_bundle
    output.join("0/0.ts").write("")
    expect { profile.verify_encode! }.to raise_error(HLS::Error, /segment missing or empty/)
  end

  it "raises when a declared poster is missing" do
    klass = Class.new(profile_class).tap { |k| k.poster :hero, scale: 1.0 }
    profile = klass.new(input: input, output: output)
    write_valid_bundle
    expect { profile.verify_encode! }.to raise_error(HLS::Error, /declared poster missing.*hero\.jpg/)
  end

  it "passes when a declared poster exists with content" do
    klass = Class.new(profile_class).tap { |k| k.poster :hero, scale: 1.0 }
    profile = klass.new(input: input, output: output)
    write_valid_bundle
    output.join("hero.jpg").write("fake jpeg data")
    expect { profile.verify_encode! }.not_to raise_error
  end
end
