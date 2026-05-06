# frozen_string_literal: true

# Loaded by the Railtie when ActiveJob is available. Plain-Ruby usage of
# the gem doesn't pull this in.
return unless defined?(ActiveJob)

module HLS
  # ActiveJob wrapper that runs a profile's full pipeline (encode + upload).
  #
  # Enqueue with:
  #
  #   HLS::EncodeJob.perform_later(
  #     profile: "CourseVideo",
  #     input:   "/path/to/source.mp4",
  #     output:  "/path/to/working/dir",
  #     key_prefix: "phlex/forms/overview"
  #   )
  class EncodeJob < ActiveJob::Base
    queue_as { ENV.fetch("HLS_QUEUE", "default") }

    # Another worker is encoding the same output dir. Retrying just
    # means we'll bump heads with them again — the lock is released
    # exactly when their work finishes, and at that point the state
    # sidecar will say `encoded?`, so the original caller can simply
    # re-enqueue if they care to verify.
    discard_on HLS::Lock::Busy

    # Malformed state.json is operator-intervention territory: retrying
    # silently re-runs the encode and re-corrupts. Surface it to the
    # dead-letter queue so someone notices.
    discard_on HLS::State::CorruptError

    def perform(profile:, input:, output:, key_prefix: nil)
      profile_class = profile.is_a?(Class) ? profile : profile.constantize
      input_obj = input.is_a?(HLS::Input) ? input : HLS::Input.new(input)

      profile_class.new(
        input: input_obj,
        output: Pathname.new(output),
        key_prefix: key_prefix
      ).process
    end
  end
end
