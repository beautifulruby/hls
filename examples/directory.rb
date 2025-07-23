
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

  package = HLS::Package::Web.new(input:, output:)

  FileUtils.mkdir_p package.output

  package.renditions.each do |media|
    FileUtils.mkdir_p media.output

    jobs.schedule do
      jobs.ffmpeg media.poster
      jobs.ffmpeg media.video
    end
  end
end

jobs.process
