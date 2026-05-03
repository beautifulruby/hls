# frozen_string_literal: true

# Encoding profile for <%= class_name %>. Inherits app-wide defaults
# from ApplicationVideo and config/initializers/hls.rb.
#
# Usage:
#
#   profile = <%= class_name %>.new(
#     input: HLS::Input.new("path/to/source.mp4"),
#     output: Pathname.new("tmp/encoded/#{id}"),
#     key_prefix: "videos/#{id}"
#   )
#   profile.process
#   # Probes input → encodes HLS multiplex + posters → uploads to bucket.
#   # Idempotent: re-running with the same input is a no-op.
#
# Then in your controller:
#
#   manifest = <%= class_name %>.manifest("videos/#{id}")
#   render plain: manifest.master_playlist
#
class <%= class_name %> < ApplicationVideo
  # Three-rendition ladder scaled off the input. Each rendition is
  # encoded only if it fits within the input dimensions (no upscaling).
  # `scale:` derives width/height from the source; pass explicit
  # `width:`/`height:`/`bitrate:` for fixed dimensions.
  rendition :high,   scale: 1.0
  rendition :medium, scale: 0.5
  rendition :small,  scale: 0.25

  # One full-size poster. Add more (thumbnails, social cards, etc.)
  # by uncommenting the lines below or adding your own.
  poster :hero, scale: 1.0
  # poster :thumbnail, width: 320, height: 180
  # poster :og,        width: 1200, height: 630   # social share card

  # Per-profile overrides. Anything left out falls back to
  # ApplicationVideo / config.hls / gem defaults.
  #
  # bits_per_pixel   :screencast   # :screencast (3), :mixed (4), :motion (6)
  # video_codec      "libx264"     # pin software encoder regardless of host
  # max_bitrate_kbps 8_000         # cap any single rendition's bitrate
  # segment_duration 2             # tighter segments → faster seeking, more files
end
