# frozen_string_literal: true

# Stand-in for HLS::Input that doesn't shell out to ffprobe. Lets tests
# control input dimensions without needing a real video file.
FakeInput = Struct.new(:width, :height, :path, keyword_init: true) do
  def initialize(width: 1920, height: 1080, path: "/tmp/fake.mp4")
    super(width: width, height: height, path: Pathname.new(path))
  end
end
