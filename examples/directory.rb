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

HLS::Directory.new(source).glob("**/*.mp4").first.tap do |input, path|
  output = destination.join(path)
  FileUtils.mkdir_p(output)

  package = HLS::Video::Dev.new(input:, output:)
  puts "Processing renditions for: #{input}"

  jobs.render package

  manifest = HLS::Manifest::Generator.new(package.output.join("index.m3u8"))

  parser = HLS::Manifest::Parser.from_json manifest.to_json

  binding.irb

  # parser = HLS::Manifest::Parser.new **package.manifest.serialize
  # parser.renditions.each do |rendition|
  #   rendition.playlist.items.each do |item|
  #     item.segment = URI.join("http://example.com", rendition.path.join(item.segment).to_s).tap do |url|
  #       url.query = "foo=bar"
  #     end
  #   end
  #   binding.irb
  # end
end

# jobs.process
