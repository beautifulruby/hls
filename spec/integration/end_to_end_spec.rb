# frozen_string_literal: true

require "spec_helper"
require "hls/testing"
require "tmpdir"

# End-to-end integration: actually shells out to ffmpeg, encodes a
# generated test source, and asserts the output bundle on disk has the
# expected layout, playlist structure, segment counts, and poster
# dimensions.
#
# This is the spec that catches command-building bugs the stubbed unit
# tests miss — wrong template patterns, off-by-one segment counts,
# scale math errors, anything where ffmpeg's interpretation of our args
# diverges from what we asserted.
#
# It also doubles as a usage example for the public HLS::Testing
# module that ships with the gem.

RSpec.describe "end-to-end encode and poster pipeline" do
  include HLS::Testing

  around do |example|
    Dir.mktmpdir("hls-e2e") do |tmp|
      @tmp = Pathname.new(tmp)
      @input_path = generate_test_video(path: @tmp.join("source.mp4"))
      example.run
    end
  end

  describe "with three scaled renditions and two posters" do
    let(:input)  { HLS::Input.new(@input_path) }
    let(:output) { @tmp.join("encoded") }

    let(:profile_class) do
      Class.new(HLS::ApplicationVideo).tap do |k|
        # Use libx264 explicitly so this spec works on Linux CI.
        k.video_codec   "libx264"
        k.audio_codec   "aac"
        k.audio_bitrate 64
        k.bits_per_pixel :screencast
        k.segment_duration 4

        k.rendition :high,   scale: 1.0   # 640×360
        k.rendition :medium, scale: 0.5   # 320×180
        k.rendition :small,  scale: 0.25  # 160×90

        k.poster :hero,      scale: 1.0
        k.poster :thumbnail, width: 160, height: 90
      end
    end

    let(:profile) { profile_class.new(input: input, output: output) }

    before do
      silence_ffmpeg do
        profile.encode!
        profile.poster!
      end
    end

    describe "the public matcher" do
      it "passes for a well-formed bundle" do
        expect(output).to be_a_valid_hls_bundle
          .with_variants(3)
          .with_posters(:hero, :thumbnail)
      end

      it "fails informatively for a bundle missing a poster" do
        result = matcher = be_a_valid_hls_bundle.with_posters(:nonexistent)
        result.matches?(output)
        expect(result.failure_message).to include("nonexistent.jpg")
      end
    end

    describe "directory layout" do
      it "writes a master playlist at the output root" do
        expect(output.join("index.m3u8")).to exist
      end

      it "writes a variant subdirectory for each rendition" do
        expect(output.join("0").directory?).to be(true)
        expect(output.join("1").directory?).to be(true)
        expect(output.join("2").directory?).to be(true)
      end

      it "writes a variant playlist inside each variant subdir" do
        %w[0 1 2].each do |variant|
          expect(output.join(variant, "index.m3u8")).to exist
        end
      end

      it "writes segment files inside each variant subdir" do
        %w[0 1 2].each do |variant|
          segments = output.join(variant).glob("*.ts")
          expect(segments.size).to be > 0,
            "expected segments in variant #{variant}, found #{segments.size}"
        end
      end

      it "writes one .jpg per declared poster at the output root" do
        expect(output.join("hero.jpg")).to exist
        expect(output.join("thumbnail.jpg")).to exist
      end

      it "writes nothing extra at the output root" do
        roots = output.children.map { |p| p.basename.to_s }.sort
        expect(roots).to eq(%w[0 1 2 hero.jpg index.m3u8 thumbnail.jpg])
      end
    end

    describe "the master playlist" do
      let(:master) { parse_playlist(output.join("index.m3u8")) }

      it "lists one stream entry per rendition" do
        expect(master.items.size).to eq(3)
      end

      it "references each variant playlist by relative path" do
        uris = master.items.map(&:uri)
        expect(uris).to contain_exactly(
          "0/index.m3u8",
          "1/index.m3u8",
          "2/index.m3u8"
        )
      end
    end

    describe "variant playlists" do
      it "produce 3 segments for a 12-second source at 4s/segment" do
        %w[0 1 2].each do |variant|
          playlist = parse_playlist(output.join(variant, "index.m3u8"))
          # Allow ±1 segment tolerance for ffmpeg's tail-segment edge cases.
          expect(playlist.items.size).to be_between(2, 4),
            "variant #{variant} had #{playlist.items.size} segments, expected ~3"
        end
      end

      it "are VOD playlists with an end marker" do
        playlist_text = output.join("0", "index.m3u8").read
        expect(playlist_text).to include("EXT-X-PLAYLIST-TYPE:VOD")
        expect(playlist_text).to include("EXT-X-ENDLIST")
      end

      it "reference segment files that exist on disk" do
        playlist = parse_playlist(output.join("0", "index.m3u8"))
        playlist.items.each do |segment|
          segment_path = output.join("0", segment.segment)
          expect(segment_path).to exist
          expect(segment_path.size).to be > 0
        end
      end
    end

    describe "posters" do
      it "renders the hero poster at input dimensions" do
        expect(probe_dimensions(output.join("hero.jpg"))).to eq([640, 360])
      end

      it "renders the thumbnail at the declared explicit dimensions" do
        expect(probe_dimensions(output.join("thumbnail.jpg"))).to eq([160, 90])
      end

      it "produces non-empty JPEG files" do
        expect(output.join("hero.jpg").size).to be > 100
        expect(output.join("thumbnail.jpg").size).to be > 100
      end
    end

    describe "rendition dimensions" do
      it "encodes each variant at the requested resolution" do
        expected = { "0" => 640, "1" => 320, "2" => 160 }
        expected.each do |variant_id, expected_width|
          segment = output.join(variant_id).glob("*.ts").sort.first
          actual_width, _ = probe_dimensions(segment)
          expect(actual_width).to eq(expected_width)
        end
      end
    end
  end

  describe "codec options actually land in the encoded segments" do
    # Unit specs assert "-tune animation" appears in the command array,
    # but that's just an array assertion — ffmpeg might silently ignore
    # an unknown flag, or a future ffmpeg might rename it. This spec
    # encodes for real and ffprobes the output to verify the codec
    # decision survived the round-trip. Catches drift between ffmpeg
    # versions and accidental flag deletions in #video_codec_options.
    let(:input) { HLS::Input.new(@input_path) }

    it "produces h264-encoded segments when video_codec is libx264" do
      output = @tmp.join("codec-libx264")
      klass = Class.new(HLS::ApplicationVideo).tap do |k|
        k.video_codec "libx264"
        k.audio_codec "aac"
        k.audio_bitrate 64
        k.rendition :only, scale: 0.5
      end
      silence_ffmpeg { klass.new(input: input, output: output).encode! }

      segment = output.join("0").glob("*.ts").sort.first
      meta = probe(segment)
      expect(meta.dig("streams", 0, "codec_name")).to eq("h264")
    end

    it "honors a custom segment_duration in the GOP arithmetic" do
      output = @tmp.join("seg-2s")
      klass = Class.new(HLS::ApplicationVideo).tap do |k|
        k.video_codec "libx264"
        k.audio_codec "aac"
        k.audio_bitrate 64
        k.segment_duration 2
        k.rendition :only, scale: 0.5
      end

      silence_ffmpeg { klass.new(input: input, output: output).encode! }

      # 12s source / 2s segments → ~6 segments. With the previous
      # hardcoded -g 180 (and 30fps source) keyframes would only land
      # every 6 seconds — segments would overrun the keyframe and
      # players would stall on seek. With gop_size = 30*2 = 60, every
      # segment starts on a keyframe. The structural test: 12s / 2s
      # produces about 6 segments, not 3.
      playlist = parse_playlist(output.join("0", "index.m3u8"))
      expect(playlist.items.size).to be_between(5, 7),
        "expected ~6 segments at 2s each from a 12s source, got #{playlist.items.size}"
    end
  end

  describe "with no posters declared" do
    let(:input)  { HLS::Input.new(@input_path) }
    let(:output) { @tmp.join("no-posters") }

    let(:profile_class) do
      Class.new(HLS::ApplicationVideo).tap do |k|
        k.video_codec "libx264"
        k.audio_codec "aac"
        k.audio_bitrate 64
        k.rendition :only, scale: 0.5
      end
    end

    it "produces no .jpg files in the output directory" do
      profile = profile_class.new(input: input, output: output)
      silence_ffmpeg do
        profile.encode!
        profile.poster!
      end

      expect(output.glob("*.jpg")).to be_empty
    end
  end
end
