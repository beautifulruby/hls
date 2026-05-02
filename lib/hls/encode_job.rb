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
