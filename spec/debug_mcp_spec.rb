# frozen_string_literal: true

RSpec.describe DebugMcp do
  it "has a version number" do
    expect(DebugMcp::VERSION).not_to be_nil
    expect(DebugMcp::VERSION).to eq("0.2.1")
  end

  describe DebugMcp::Error do
    it "is a StandardError" do
      expect(DebugMcp::Error.new).to be_a(StandardError)
    end
  end

  describe DebugMcp::ConnectionError do
    it "is a DebugMcp::Error" do
      expect(DebugMcp::ConnectionError.new).to be_a(DebugMcp::Error)
    end

    it "stores final_output" do
      err = DebugMcp::ConnectionError.new("msg", final_output: "some output")
      expect(err.message).to eq("msg")
      expect(err.final_output).to eq("some output")
    end

    it "defaults final_output to nil" do
      err = DebugMcp::ConnectionError.new("msg")
      expect(err.final_output).to be_nil
    end
  end

  describe DebugMcp::SessionError do
    it "is a DebugMcp::Error" do
      expect(DebugMcp::SessionError.new).to be_a(DebugMcp::Error)
    end

    it "stores final_output" do
      err = DebugMcp::SessionError.new("msg", final_output: "output")
      expect(err.message).to eq("msg")
      expect(err.final_output).to eq("output")
    end
  end

  describe DebugMcp::TimeoutError do
    it "is a DebugMcp::Error" do
      expect(DebugMcp::TimeoutError.new).to be_a(DebugMcp::Error)
    end
  end
end
