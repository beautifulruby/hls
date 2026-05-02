# frozen_string_literal: true

require "pathname"

module HLS
  # Advisory file lock for an encode run. Two workers asked to process
  # the same output directory at the same time would corrupt each
  # other's state.json and leave a half-uploaded bundle. The lock
  # makes that case fail loudly instead of silently.
  #
  # Uses `flock` with `LOCK_EX | LOCK_NB` — the second process gets
  # `HLS::Lock::Busy` immediately rather than blocking. The lock file
  # itself (`<output>/.hls-lock`) is left on disk; only the kernel-level
  # advisory lock is released. This keeps the file's inode stable so
  # `flock` works reliably across re-runs.
  class Lock
    FILENAME = ".hls-lock"

    class Busy < HLS::Error; end

    def self.acquire(output_dir, &block)
      new(output_dir).acquire(&block)
    end

    attr_reader :path

    def initialize(output_dir)
      @path = Pathname.new(output_dir).join(FILENAME)
    end

    # Acquires the lock, yields, releases. If another process holds it,
    # raises `HLS::Lock::Busy` immediately — we don't wait.
    def acquire
      @path.parent.mkpath
      File.open(@path, File::CREAT | File::RDWR, 0o644) do |f|
        unless f.flock(File::LOCK_EX | File::LOCK_NB)
          raise Busy, "another process is already encoding #{@path.parent}"
        end
        f.truncate(0)
        f.write("#{Process.pid}\n")
        f.flush
        begin
          yield
        ensure
          f.flock(File::LOCK_UN)
        end
      end
    end
  end
end
