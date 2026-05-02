# frozen_string_literal: true

# Mirrors the production wiring: a config initializer sets HLS defaults
# AFTER the gem's Railtie has been declared. The Railtie's apply_config
# initializer runs AFTER :load_config_initializers, so settings here
# end up applied to HLS::ApplicationVideo.
Rails.application.config.hls.signing_ttl = 7200
