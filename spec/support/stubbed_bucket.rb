# frozen_string_literal: true

require "aws-sdk-s3"

# Helpers for spinning up a stubbed Aws::S3::Bucket where individual keys
# return canned bodies. The aws-sdk supports stub_responses out of the
# box; this just sugars it for the manifest specs.
module StubbedBucket
  module_function

  # Build an Aws::S3::Bucket whose `bucket.object(key).get` returns the
  # body from `objects[key]`.
  def build(name: "test-bucket", objects: {})
    client = Aws::S3::Client.new(stub_responses: true, region: "auto")

    objects.each do |key, body|
      client.stub_responses(:get_object, ->(context) {
        if context.params[:key] == key
          { body: body }
        else
          "NoSuchKey"
        end
      })
    end

    # Above stub only works for one key; for multi-key, install a single
    # callback that dispatches by key:
    if objects.size > 1
      client.stub_responses(:get_object, ->(context) {
        key = context.params[:key]
        if objects.key?(key)
          { body: objects[key] }
        else
          "NoSuchKey"
        end
      })
    end

    Aws::S3::Resource.new(client: client).bucket(name)
  end
end
