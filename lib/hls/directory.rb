# frozen_string_literal: true

require "pathname"

module HLS
  # Walks a source directory and yields `(input, relative_output_dir)`
  # pairs for each matching file. The relative output dir drops the
  # source's extension so callers can join it onto a destination root.
  #
  # Example:
  #
  #   HLS::Directory.new("uploads").glob("**/*.mp4").each do |input, output|
  #     # input is an HLS::Input
  #     # output is a Pathname like "course/lecture-01" (no extension)
  #   end
  class Directory
    include Enumerable

    def initialize(source)
      @source = Pathname.new(source)
    end

    def glob(pattern)
      @pattern = pattern
      self
    end

    def each(&block)
      raise ArgumentError, "call .glob(pattern) before iterating" unless @pattern

      @source.glob(@pattern).each do |path|
        relative = path.relative_path_from(@source)
        output = relative.dirname.join(relative.basename(path.extname))
        yield Input.new(path), output
      end
    end
  end
end
