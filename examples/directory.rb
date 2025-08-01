require "bundler/inline"

gemfile do
  source "https://rubygems.org"

  gem "hls", path: ".."
end

require "fileutils"

storage = Pathname.new(ENV.fetch("SOURCE_PATH", "/Users/bradgessler/Desktop"))
source = storage.join("Exports")
destination = storage.join("Uploads")

HLS::Jobs.process do |jobs|
  directory = HLS::Directory.new(source).glob("**/*.mp4")
  puts "Processing #{directory.count} files from #{source}"
  directory.each do |input, path|
    output = destination.join(path)
    FileUtils.mkdir_p(output)

    puts "Processing #{input.path} to #{output}"

    package = HLS::Video::Scalable.new(input:, output:)
    jobs.render package

    poster = HLS::Poster.new(input:, output:)
    jobs.render poster

    puts "Completed #{input.path} to #{output}"
  end
end
