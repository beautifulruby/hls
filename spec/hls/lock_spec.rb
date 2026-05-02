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

  it "hands off encode work across processes via lock + state.json" do
    # Realistic two-worker race: A acquires the lock and partially
    # records its uploads to state.json, then dies (oncall kills it,
    # OOM, container scheduled away). B sees the lock as held and
    # bails. After A is gone, C acquires the lock and picks up where A
    # left off — its upload pass skips the keys A already recorded.
    pid_a = fork do
      HLS::Lock.acquire(@tmp) do
        state = HLS::State.load(@tmp)
        state.record_encode(input_digest: "sha256:abc", profile: "A", renditions: [])
        state.record_upload(relative_key: "0/0.ts", digest: "deadbeef", etag: "a-etag")
        state.save
        @tmp.join("a-recorded").write("y")
        sleep 30
      end
    end

    # Wait for A to record progress to state.json
    deadline = Time.now + 3
    until @tmp.join("a-recorded").exist? || Time.now > deadline
      sleep 0.05
    end

    # Worker B: rejected immediately because A holds the lock.
    expect {
      HLS::Lock.acquire(@tmp) { }
    }.to raise_error(HLS::Lock::Busy)

    # Kill A. The kernel drops the flock automatically.
    Process.kill("KILL", pid_a)
    Process.waitpid(pid_a)

    # Worker C: acquires cleanly, reads state.json, sees A's recorded
    # upload — and would skip re-uploading 0/0.ts on its uploader pass.
    seen = nil
    HLS::Lock.acquire(@tmp) do
      state = HLS::State.load(@tmp)
      seen = state.uploaded?(relative_key: "0/0.ts", digest: "deadbeef")
    end
    expect(seen).to be(true)
  end

  it "releases the kernel-level lock when the holding process is SIGKILLed mid-encode" do
    # Realistic failure mode: oncall kills a stuck worker. The flock
    # is advisory at the kernel level — when the process dies, the
    # kernel drops it automatically. A subsequent worker should be
    # able to re-acquire without manual cleanup.
    pid = fork do
      described_class.acquire(@tmp) do
        @tmp.join("acquired").write("y")
        sleep 30  # would never get here in normal life — we're going to kill it
      end
    end

    deadline = Time.now + 3
    until @tmp.join("acquired").exist? || Time.now > deadline
      sleep 0.05
    end

    Process.kill("KILL", pid)
    Process.waitpid(pid)

    # The lock file is still on disk — that's fine, only the kernel
    # advisory lock matters. New worker should grab it cleanly.
    expect {
      described_class.acquire(@tmp) { }
    }.not_to raise_error
  end
end
