require "bundler/inline"

gemfile do
  source "https://rubygems.org"

  gem "hls", path: ".."
  gem "parallel"
end

require "fileutils"
require "pathname"
require "etc"
require "shellwords"
require "uri"

storage = Pathname.new(ENV.fetch("SOURCE_PATH", "/Users/bradgessler/Desktop"))
source = storage.join("Exports")
destination = storage.join("Uploads")

CONCURRENCY = Etc.nprocessors / 2

class Jobs
  include Enumerable

  def initialize
    @jobs = []
  end

  def schedule(&job)
    @jobs << job
  end

  def render(rendition)
    schedule do
      puts "[#{rendition}] Processing"
      ffmpeg rendition
      puts "[#{rendition}] Done"
    end
  end

  def process(in_processes: CONCURRENCY, **options)
    Parallel.each(@jobs, in_processes: in_processes, &:call)
  end

  private

  def ffmpeg(task)
    cmd = task.command.map(&:to_s)
    puts "[#{task.class.name}] Running: #{Shellwords.join(cmd)}"
    system(*cmd)
    puts "[#{task.class.name}] Done"
  end
end

jobs = Jobs.new


directory = HLS::Directory.new(source).glob("**/*.mp4")
puts "Processing #{directory.count} files from #{source}"
directory.each do |input, path|
  output = destination.join(path)
  FileUtils.mkdir_p(output)

  puts "Processing #{input.path} to #{output}"

  package = HLS::Video::Scalable.new(input:, output:)
  # jobs.render package

  poster = HLS::Poster.new(input:, output:)
  jobs.render poster

  puts "Completed #{input.path} to #{output}"
end

jobs.process
