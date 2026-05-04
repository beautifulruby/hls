# frozen_string_literal: true

require "spec_helper"

RSpec.describe HLS::Cache do
  # Mimics the Rails.cache fetch shape: stores [value, expires_in] so
  # tests can introspect the TTL the wrapper passed through.
  class FakeBackend
    attr_reader :store
    def initialize; @store = {}; end
    def fetch(key, expires_in: nil)
      @store[key] ||= [yield, expires_in]
      @store[key].first
    end
  end

  let(:backend) { FakeBackend.new }

  it "delegates fetch to the backend with the configured TTL" do
    cache = described_class.new(backend: backend, ttl: 90)
    cache.fetch("k") { "v" }
    expect(backend.store["k"]).to eq(["v", 90])
  end

  it "defaults TTL to DEFAULT_TTL when not supplied" do
    cache = described_class.new(backend: backend)
    cache.fetch("k") { "v" }
    expect(backend.store["k"].last).to eq(described_class::DEFAULT_TTL)
  end

  it "yields only on a miss; subsequent fetches return cached value without re-yielding" do
    cache = described_class.new(backend: backend, ttl: 60)
    yields = 0
    cache.fetch("k") { yields += 1; "v" }
    cache.fetch("k") { yields += 1; "should not be called" }
    expect(yields).to eq(1)
  end

  it "coerces ttl to an integer" do
    cache = described_class.new(backend: backend, ttl: "120")
    expect(cache.ttl).to eq(120)
  end
end
