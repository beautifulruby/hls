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

  def process(in_processes: CONCURRENCY, **options)
    Parallel.each(@jobs, in_processes: in_processes, &:call)
  end
end

jobs = Jobs.new

def run_ffmpeg(task)
  cmd = task.command.map(&:to_s)
  puts "[#{task.class.name}] Running: #{Shellwords.join(cmd)}"
  system(*cmd)
  puts "[#{task.class.name}] Done"
end

HLS::Directory.new(source).glob("**/*.mp4").each do |input, path|
  output = destination.join(path)
  FileUtils.mkdir_p(output)

  package = HLS::Package::Web.new(input:, output:)
  puts "Processing renditions for: #{input}"

  package.renditions.each do |media|
    FileUtils.mkdir_p(media.output)

    # jobs.schedule do
    #   run_ffmpeg(media.poster)
    #   run_ffmpeg(media.video)
    # end
  end

  pp HLS::Manifest::Parser.from_json package.manifest.to_json
end

jobs.process
