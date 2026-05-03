# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/hls/install/install_generator"

RSpec.describe Hls::Generators::InstallGenerator, type: :generator do
  around do |example|
    Dir.mktmpdir do |tmp|
      @destination = Pathname.new(tmp)
      example.run
    end
  end

  def run_generator
    described_class.start([], destination_root: @destination.to_s)
  end

  before { run_generator }

  it "creates the initializer at config/initializers/hls.rb" do
    initializer = @destination.join("config/initializers/hls.rb")
    expect(initializer).to exist
  end

  it "wires Rails.application.config.hls inside the initializer" do
    initializer = @destination.join("config/initializers/hls.rb").read
    expect(initializer).to include("Rails.application.config.hls.tap")
    expect(initializer).to include("hls.s3_resource =")
    expect(initializer).to include("hls.bucket =")
    expect(initializer).to include("hls.signing_ttl =")
    expect(initializer).to include("hls.segment_duration =")
  end

  it "documents the optional knobs as commented examples" do
    initializer = @destination.join("config/initializers/hls.rb").read
    expect(initializer).to include("# hls.ffmpeg_timeout =")
    expect(initializer).to include("# hls.manifest_cache =")
  end

  it "creates the ApplicationVideo base class" do
    base = @destination.join("app/videos/application_video.rb")
    expect(base).to exist
    expect(base.read).to include("class ApplicationVideo < HLS::ApplicationVideo")
  end

  it "scaffolds ApplicationVideo with everything commented out so it's a no-op until edited" do
    body = @destination.join("app/videos/application_video.rb").read
    # No active DSL calls — everything inside the class is a comment.
    inside_class = body[/class ApplicationVideo.*?\nend/m]
    code_lines = inside_class.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") || l =~ /\A(class|end)\b/ }
    expect(code_lines).to be_empty
  end
end
