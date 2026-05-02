# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe HLS::Lock do
  around do |example|
    Dir.mktmpdir { |tmp| @tmp = Pathname.new(tmp); example.run }
  end

  it "yields when the lock is free" do
    yielded = false
    described_class.acquire(@tmp) { yielded = true }
    expect(yielded).to be(true)
  end

  it "creates the output directory if missing" do
    nested = @tmp.join("does/not/exist/yet")
    described_class.acquire(nested) { }
    expect(nested).to be_directory
  end

  it "writes a lock file at .hls-lock" do
    described_class.acquire(@tmp) { }
    expect(@tmp.join(HLS::Lock::FILENAME)).to exist
  end

  it "records the holder PID in the lock file while held" do
    described_class.acquire(@tmp) do
      contents = @tmp.join(HLS::Lock::FILENAME).read
      expect(contents.strip).to eq(Process.pid.to_s)
    end
  end

  it "raises Busy when another process holds the lock" do
    other_pid = fork do
      described_class.acquire(@tmp) do
        # Signal parent we have the lock by creating a marker file...
        @tmp.join("acquired").write("y")
        sleep 5
      end
    end

    # Wait for the child to take the lock.
    deadline = Time.now + 3
    until @tmp.join("acquired").exist? || Time.now > deadline
      sleep 0.05
    end

    expect {
      described_class.acquire(@tmp) { }
    }.to raise_error(HLS::Lock::Busy, /already encoding/)
  ensure
    Process.kill("TERM", other_pid) rescue nil
    Process.wait(other_pid) rescue nil
  end

  it "releases the lock after the block returns, allowing re-acquisition" do
    described_class.acquire(@tmp) { }
    expect {
      described_class.acquire(@tmp) { }
    }.not_to raise_error
  end

  it "releases the lock when the block raises" do
    expect {
      described_class.acquire(@tmp) { raise "boom" }
    }.to raise_error("boom")

    expect {
      described_class.acquire(@tmp) { }
    }.not_to raise_error
  end
end
