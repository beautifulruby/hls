require "bundler/inline"

gemfile do
  source "https://rubygems.org"

  gem "hls", path: ".."
end

require "fileutils"

storage = Pathname.new(ENV.fetch("SOURCE_PATH", "/Users/bradgessler/Desktop"))
source = storage.join("Exports")
destination = storage.join("Uploads")

class CourseVideo < HLS::ApplicationVideo
  bits_per_pixel :screencast

  rendition :full,   scale: 1.0
  rendition :medium, scale: 0.5
  rendition :small,  scale: 0.25

  poster :poster, scale: 1.0
end

directory = HLS::Directory.new(source).glob("**/*.mp4").to_a
puts "Processing #{directory.size} files from #{source}"

directory.each do |input, path|
  output = destination.join(path)
  FileUtils.mkdir_p(output)

  puts "Processing #{input.path} to #{output}"

  profile = CourseVideo.new(input:, output:)
  profile.encode!
  profile.poster!

  puts "Completed #{input.path} to #{output}"
end
