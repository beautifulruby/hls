# frozen_string_literal: true

# Mirrors the production wiring: an initializer subscribes to the
# :hls_application_video load hook and configures profiles directly.
# The hook fires from the gem's Railtie after :load_config_initializers,
# so by the time this block runs ApplicationVideo and its DSL are
# available.
ActiveSupport.on_load(:hls_application_video) do
  signing_ttl 7200
end
