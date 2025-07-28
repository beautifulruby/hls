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

storage = Pathname.new("/Users/bradgessler/Desktop")
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
      ffmpeg rendition
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

HLS::Directory.new(source).glob("**/*.mp4").each do |input, path|
  output = destination.join(path)
  FileUtils.mkdir_p(output)

  package = HLS::Video::Scalable.new(input:, output:)
  puts "Processing renditions for: #{input}"

  jobs.render package
end

jobs.process
