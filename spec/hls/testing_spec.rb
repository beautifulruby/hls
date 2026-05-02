# frozen_string_literal: true

require "spec_helper"
require "hls/testing"

RSpec.describe HLS::Testing, "matchers" do
  include HLS::Testing

  describe "resolve_variants_under" do
    # Build a fake M3u8::Playlist with the given variant URIs.
    def playlist_with(uris)
      list = M3u8::Playlist.new
      list.items = uris.map do |uri|
        item = M3u8::PlaylistItem.new(
          program_id: 1,
          width: 1920,
          height: 1080,
          codecs: "avc1",
          bandwidth: 5_000_000,
          uri: uri
        )
        item
      end
      list
    end

    let(:master_url) { "https://app.example.com/videos/course/01.m3u8" }

    it "passes when variant URIs resolve cleanly under the master URL" do
      list = playlist_with(%w[01/0.m3u8 01/1.m3u8 01/2.m3u8])
      expect(list).to resolve_variants_under(master_url)
    end

    it "fails when variant URIs include the master path prefix (the doubling bug)" do
      # These URIs include "course/" — so resolved against
      # https://app.example.com/videos/course/01.m3u8 they land at
      # /videos/course/course/01/0.m3u8 (path doubled). The matcher
      # detects this because the resolved path no longer extends the
      # master path /videos/course/01.
      list = playlist_with([
        "course/01/0.m3u8",
        "course/01/1.m3u8"
      ])

      expect {
        expect(list).to resolve_variants_under(master_url)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /should extend the master path/)
    end

    it "passes for absolute variant URIs that don't double the master path" do
      list = playlist_with(%w[
        https://cdn.example.com/streams/01/0.m3u8
        https://cdn.example.com/streams/01/1.m3u8
      ])
      expect(list).to resolve_variants_under(master_url)
    end

    it "fails on an empty master playlist" do
      list = playlist_with([])
      expect {
        expect(list).to resolve_variants_under(master_url)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /no variant streams/)
    end

    describe "with .matching(pattern)" do
      it "passes when every resolved URL matches the pattern" do
        list = playlist_with(%w[01/0.m3u8 01/1.m3u8])
        expect(list).to resolve_variants_under(master_url)
          .matching(%r{/videos/course/01/\d+\.m3u8\z})
      end

      it "fails when a resolved URL does not match the pattern" do
        list = playlist_with(%w[01/0.m3u8 01/foo.txt])
        expect {
          expect(list).to resolve_variants_under(master_url)
            .matching(%r{/\d+\.m3u8\z})
        }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /did not match/)
      end
    end

    it "fails clearly when given a non-playlist object" do
      expect {
        expect("not a playlist").to resolve_variants_under(master_url)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /M3u8::Playlist/)
    end
  end
end
