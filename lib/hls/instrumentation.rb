# frozen_string_literal: true

module HLS
  # Lightweight instrumentation wrapper around ActiveSupport::Notifications.
  #
  # Subscribe to the events from your host app to wire up logging,
  # metrics, or tracing. Event names follow the Rails convention
  # `<action>.<library>` so they show up nicely in LogSubscriber output.
  #
  #   ActiveSupport::Notifications.subscribe("encode.hls") do |name, start, finish, _, payload|
  #     Rails.logger.info "[hls] encoded #{payload[:profile]} in #{((finish - start) * 1000).round}ms"
  #   end
  #
  # Events emitted:
  #
  #   encode.hls         — encode! finished. payload: profile, output, renditions
  #   poster.hls         — poster! finished. payload: profile, output, count
  #   verify.hls         — verify_encode! passed. payload: profile, output
  #   upload_object.hls  — single object PUT to the bucket. payload: key, bytes, content_type
  #   process.hls        — full process pipeline. payload: profile, key_prefix, uploaded, skipped
  #
  # When ActiveSupport::Notifications isn't loaded (plain-Ruby usage,
  # specs without Rails), the helper is a no-op that still yields.
  module Instrumentation
    module_function

    # Wraps a block in an ActiveSupport::Notifications event. Yields the
    # mutable payload hash to the block so callers can attach result
    # data (e.g., uploaded counts) before the event is published. When
    # ActiveSupport::Notifications isn't loaded, yields the same payload
    # hash with no surrounding instrumentation.
    def instrument(event, payload = {})
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument("#{event}.hls", payload) { yield payload if block_given? }
      else
        yield payload if block_given?
      end
    end
  end
end
