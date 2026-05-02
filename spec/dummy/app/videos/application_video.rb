# frozen_string_literal: true

class ApplicationVideo < HLS::ApplicationVideo
  bucket "dummy-bucket"
  signing_ttl 1800
end
