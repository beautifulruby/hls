# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "active_job/test_helper"
require "hls/encode_job"

RSpec.describe HLS::EncodeJob do
  include ActiveJob::TestHelper

  before(:all) do
    ActiveJob::Base.queue_adapter = :test
  end

  let(:profile_class) do
    stub_const("TestProfileForJob", Class.new(HLS::ApplicationVideo).tap do |k|
      k.bucket "test-bucket"
      k.rendition :full, scale: 1.0
    end)
  end

  it "calls profile.process with the resolved profile class and input" do
    profile_class

    fake_profile = double("profile_instance", process: { uploaded: 0, skipped: 0 })
    expect(TestProfileForJob).to receive(:new).with(
      input: instance_of(HLS::Input),
      output: Pathname.new("/tmp/out"),
      key_prefix: "videos/foo"
    ).and_return(fake_profile)

    described_class.perform_now(
      profile: "TestProfileForJob",
      input: "/tmp/source.mp4",
      output: "/tmp/out",
      key_prefix: "videos/foo"
    )

    expect(fake_profile).to have_received(:process)
  end

  it "accepts a class directly as the profile argument" do
    profile_class

    fake_profile = double("profile_instance", process: nil)
    expect(TestProfileForJob).to receive(:new).and_return(fake_profile)

    described_class.perform_now(
      profile: TestProfileForJob,
      input: "/tmp/source.mp4",
      output: "/tmp/out"
    )
  end

  it "passes through an HLS::Input directly without re-wrapping" do
    profile_class

    input = HLS::Input.new("/tmp/source.mp4")
    fake_profile = double("profile_instance", process: nil)

    expect(TestProfileForJob).to receive(:new).with(
      input: input,
      output: kind_of(Pathname),
      key_prefix: nil
    ).and_return(fake_profile)

    described_class.perform_now(
      profile: TestProfileForJob,
      input: input,
      output: "/tmp/out"
    )
  end

  it "enqueues correctly via perform_later" do
    profile_class

    described_class.queue_adapter.enqueued_jobs.clear
    described_class.perform_later(
      profile: "TestProfileForJob",
      input: "/tmp/source.mp4",
      output: "/tmp/out"
    )

    enqueued = described_class.queue_adapter.enqueued_jobs
    expect(enqueued.size).to eq(1)
    expect(enqueued.first[:job]).to eq(described_class)
  end
end
