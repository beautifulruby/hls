# frozen_string_literal: true

module HLS
  # Wraps a Rails.cache-shaped backend with a TTL so the read-side
  # Manifest can call `cache.fetch(key) { ... }` without plumbing the
  # TTL alongside the backend at every call site.
  #
  # Profile classes attach an instance via `cache`:
  #
  #   class CourseVideo < ApplicationVideo
  #     def self.cache = HLS::Cache.new(backend: Rails.cache, ttl: 5.minutes)
  #   end
  #
  # The Manifest also accepts any object responding to
  # `fetch(key, &block)` directly — wrapping is just the convenience
  # path for backends like Rails.cache that need a TTL hint.
  class Cache
    DEFAULT_TTL = 300

    attr_reader :backend, :ttl

    def initialize(backend:, ttl: DEFAULT_TTL)
      @backend = backend
      @ttl = Integer(ttl)
    end

    def fetch(key, &block)
      backend.fetch(key, expires_in: ttl, &block)
    end
  end
end
