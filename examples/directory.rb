
require "bundler/inline"

gemfile do
  source "https://rubygems.org"

  # Include the local hls gem
  gem "hls", path: ".."
end

require "fileutils"

storage = Pathname.new("/Users/bradgessler/Desktop")
source = storage.join("Exports")
destination = storage.join("Uploads")

jobs = HLS::Pool.new

# Handle Ctrl+C gracefully
Signal.trap("INT") do
  puts "\nShutting down gracefully..."
  jobs.shutdown
  exit 0
end

HLS::Directory.new(source).glob("**/*.mp4").each do |input, path|
  # relative = input.relative_path_from(source)
  # target = destination.join relative.dirname.join(relative.basename(input.extname))
  output = destination.join(path)

  package = HLS::Package.new(input:, output:).tap do
    it.rendition width: 640,  height: 360,  bitrate: 500
    it.rendition width: 854,  height: 480,  bitrate: 1000
    it.rendition width: 1280, height: 720,  bitrate: 3000
    it.rendition width: 1920, height: 1080, bitrate: 6000
    it.rendition width: 3840, height: 2160, bitrate: 12000
  end

  FileUtils.mkdir_p package.output

  package.renditions.each do |media|
    FileUtils.mkdir_p media.output

    jobs.schedule do
      jobs.ffmpeg media.poster
      jobs.ffmpeg p media.video
    end
  end
end

jobs.process
