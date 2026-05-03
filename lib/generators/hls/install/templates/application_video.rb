# frozen_string_literal: true

# Base class for every video profile in this app. Defaults set here
# (or in config/initializers/hls.rb) flow down to subclasses unless
# overridden. Per-profile classes live alongside this file at
# app/videos/<name>_video.rb — generate one with:
#
#   bin/rails g hls:video Course
#
class ApplicationVideo < HLS::ApplicationVideo
  # Examples of app-wide overrides. Uncomment to apply to every
  # subclass. Anything left commented falls back to the value set in
  # config/initializers/hls.rb (or the gem's built-in default).
  #
  # video_codec      :h264          # auto-resolves the best encoder
  # audio_codec      "aac"
  # bits_per_pixel   :screencast    # :screencast (3), :mixed (4), :motion (6)
  # max_bitrate_kbps 15_000
end
