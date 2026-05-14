# frozen_string_literal: true

RSpec.describe DebugMcp::SourceTagging do
  describe ".wrap" do
    it "wraps a simple expression with begin/ensure" do
      out = described_class.wrap("1 + 1")
      expect(out).to start_with("begin;")
      expect(out).to include("(1 + 1)")
      expect(out).to include("ensure")
      expect(out).to end_with("end")
    end

    it "sets the Thread-local to :debug_eval" do
      out = described_class.wrap("expr")
      expect(out).to include("Thread.current[:_debug_mcp_event_source]=:debug_eval")
    end

    it "saves and restores the previous Thread-local value" do
      out = described_class.wrap("expr")
      expect(out).to include("__debug_mcp_prev_src=Thread.current[:_debug_mcp_event_source]")
      expect(out).to include("ensure Thread.current[:_debug_mcp_event_source]=__debug_mcp_prev_src")
    end

    it "produces a Ruby expression whose value is the wrapped code's value" do
      # Smoke check: the begin/ensure form should evaluate to the inner expression
      # (Ruby's begin..ensure..end returns the main block's value, not ensure's).
      wrapped = described_class.wrap("42")
      expect(eval(wrapped)).to eq(42)
    end

    it "restores the previous source after evaluation (when run for real)" do
      Thread.current[:_debug_mcp_event_source] = :outer_value
      eval(described_class.wrap("nil"))
      expect(Thread.current[:_debug_mcp_event_source]).to eq(:outer_value)
    ensure
      Thread.current[:_debug_mcp_event_source] = nil
    end

    it "sets :debug_eval during evaluation and restores afterwards" do
      Thread.current[:_debug_mcp_event_source] = nil
      observed = nil
      eval(described_class.wrap("observed = Thread.current[:_debug_mcp_event_source]; nil"))
      expect(observed).to eq(:debug_eval)
      expect(Thread.current[:_debug_mcp_event_source]).to be_nil
    end

    it "restores previous source even when the wrapped code raises" do
      Thread.current[:_debug_mcp_event_source] = :outer
      expect {
        eval(described_class.wrap("raise 'boom'"))
      }.to raise_error("boom")
      expect(Thread.current[:_debug_mcp_event_source]).to eq(:outer)
    ensure
      Thread.current[:_debug_mcp_event_source] = nil
    end
  end
end
