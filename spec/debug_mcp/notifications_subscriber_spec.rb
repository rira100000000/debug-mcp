# frozen_string_literal: true

RSpec.describe DebugMcp::NotificationsSubscriber do
  let(:client) { build_mock_client }

  describe ".install" do
    context "when target is not a Rails app" do
      before { allow(DebugMcp::RailsHelper).to receive(:rails?).with(client).and_return(false) }

      it "returns false without sending commands" do
        expect(client).not_to receive(:send_command)
        expect(described_class.install(client)).to be false
      end
    end

    context "when target is a Rails app" do
      before { allow(DebugMcp::RailsHelper).to receive(:rails?).with(client).and_return(true) }

      it "sends a Base64-encoded eval command and reports success on confirmation token" do
        allow(client).to receive(:send_command) do |cmd|
          expect(cmd).to include("eval(::Base64.decode64(")
          ":debug_mcp_subscriber_ok"
        end
        expect(described_class.install(client)).to be true
      end

      it "returns false when the confirmation token is missing" do
        allow(client).to receive(:send_command).and_return("SyntaxError: ...")
        expect(described_class.install(client)).to be false
      end

      it "returns false when send_command raises DebugMcp::Error" do
        allow(client).to receive(:send_command).and_raise(DebugMcp::Error.new("boom"))
        expect(described_class.install(client)).to be false
      end

      it "refuses to inject in trap context without sending any command" do
        allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(true)
        expect(client).not_to receive(:send_command)
        expect(described_class.install(client)).to be false
      end
    end
  end

  describe ".fetch_last" do
    it "requests the last n events and decodes the response" do
      allow(client).to receive(:send_command) do |cmd|
        expect(cmd).to include("fetch_last(5)")
        debug_eval_json([{ name: "sql.active_record", seq: 2 }])
      end
      result = described_class.fetch_last(client, 5)
      expect(result.size).to eq(1)
      expect(result.first[:seq]).to eq(2)
    end

    it "coerces n to an integer to avoid injection" do
      allow(client).to receive(:send_command) do |cmd|
        expect(cmd).to include("fetch_last(5)")
        expect(cmd).not_to include("system")
        "[]"
      end
      described_class.fetch_last(client, "5; system('x')")
    end

    it "returns empty array on DebugMcp::Error" do
      allow(client).to receive(:send_command).and_raise(DebugMcp::Error.new("boom"))
      expect(described_class.fetch_last(client, 5)).to eq([])
    end
  end

  describe ".fetch_after_seq" do
    it "requests events after the cursor and decodes the response" do
      allow(client).to receive(:send_command) do |cmd|
        expect(cmd).to include("fetch_after_seq(7)")
        debug_eval_json([{ name: "enqueue.active_job", seq: 8 }])
      end
      result = described_class.fetch_after_seq(client, 7)
      expect(result.first[:seq]).to eq(8)
    end

    it "coerces the cursor to an integer" do
      allow(client).to receive(:send_command) do |cmd|
        expect(cmd).to include("fetch_after_seq(7)")
        expect(cmd).not_to include("danger")
        "[]"
      end
      described_class.fetch_after_seq(client, "7; danger")
    end
  end

  describe ".metadata" do
    it "decodes a base64 JSON object response into a symbolized hash" do
      meta_obj = { version: "2", installed: true, dropped_count: 0, newest_seq: 5 }
      allow(client).to receive(:send_command).and_return(debug_eval_json(meta_obj))
      meta = described_class.metadata(client)
      expect(meta[:version]).to eq("2")
      expect(meta[:installed]).to be true
      expect(meta[:newest_seq]).to eq(5)
    end

    it "returns empty hash when no base64 result is present" do
      allow(client).to receive(:send_command).and_return("=> nil\n")
      expect(described_class.metadata(client)).to eq({})
    end

    it "returns empty hash on DebugMcp::Error" do
      allow(client).to receive(:send_command).and_raise(DebugMcp::Error.new("boom"))
      expect(described_class.metadata(client)).to eq({})
    end
  end

  describe ".fetch_by_request_id" do
    it "returns empty array when request_id is nil" do
      expect(client).not_to receive(:send_command)
      expect(described_class.fetch_by_request_id(client, nil)).to eq([])
    end

    it "decodes a base64 JSON array response into symbolized hashes" do
      events = [{ name: "sql.active_record", timestamp: 1.0, duration_ms: 2.5,
                  request_id: "abc", data: { sql: "SELECT 1" } }]
      allow(client).to receive(:send_command).and_return(debug_eval_json(events))
      result = described_class.fetch_by_request_id(client, "abc")
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
      expect(result.first[:name]).to eq("sql.active_record")
      expect(result.first[:data][:sql]).to eq("SELECT 1")
    end

    it "returns empty array when no base64 result is present" do
      allow(client).to receive(:send_command).and_return("=> nil\n")
      expect(described_class.fetch_by_request_id(client, "abc")).to eq([])
    end

    it "returns empty array when the response is malformed" do
      allow(client).to receive(:send_command).and_return("=> \"not base64 json\"\n")
      expect(described_class.fetch_by_request_id(client, "abc")).to eq([])
    end

    it "returns empty array on DebugMcp::Error" do
      allow(client).to receive(:send_command).and_raise(DebugMcp::Error.new("boom"))
      expect(described_class.fetch_by_request_id(client, "abc")).to eq([])
    end
  end

  describe ".fetch_since" do
    it "sends timestamp as float and decodes the response" do
      allow(client).to receive(:send_command) do |cmd|
        expect(cmd).to include("123.45")
        debug_eval_json([{ name: "render_template.action_view" }])
      end
      result = described_class.fetch_since(client, 123.45)
      expect(result.size).to eq(1)
      expect(result.first[:name]).to eq("render_template.action_view")
    end
  end

  describe "INJECTION_CODE" do
    it "defines the DebugMcpNotificationsBuffer module guarded by `unless defined?`" do
      expect(described_class::INJECTION_CODE).to include("unless defined?(::DebugMcpNotificationsBuffer)")
      expect(described_class::INJECTION_CODE).to include("module ::DebugMcpNotificationsBuffer")
    end

    it "subscribes to all configured event names" do
      described_class::SUBSCRIBED_EVENTS.each do |name|
        expect(described_class::INJECTION_CODE).to include(name)
      end
    end

    it "calls install at the end of injection" do
      expect(described_class::INJECTION_CODE).to include("::DebugMcpNotificationsBuffer.install")
    end

    it "reads the event source from Thread.current (ADR-0003)" do
      expect(described_class::INJECTION_CODE).to include("Thread.current[:_debug_mcp_event_source]")
      expect(described_class::INJECTION_CODE).to include("source: src")
    end

    it "calls install OUTSIDE the `unless defined?` guard so re-injection recovers" do
      # The activation call must be the final statement, not nested inside the
      # `unless defined?` block — otherwise a module left with zero subscriptions
      # (e.g. a trap-context install attempt) can never re-subscribe.
      lines = described_class::INJECTION_CODE.lines.map(&:strip).reject(&:empty?)
      expect(lines.last).to eq("::DebugMcpNotificationsBuffer.install")
    end

    it "is versioned so an older injected module is replaced" do
      expect(described_class::INJECTION_CODE).to include(described_class::VERSION.inspect)
      expect(described_class::INJECTION_CODE).to include("def version")
    end
  end

  # Self-contained integration: evaluate the real INJECTION_CODE in this process
  # (ActiveSupport is a test dependency) and exercise the lifecycle directly.
  describe "INJECTION_CODE behavior (in-process)", :integration do
    before(:all) do
      require "active_support"
      require "active_support/notifications"
    rescue LoadError
      skip "ActiveSupport not available"
    end

    after do
      if defined?(::DebugMcpNotificationsBuffer)
        ::DebugMcpNotificationsBuffer.uninstall
        Object.send(:remove_const, :DebugMcpNotificationsBuffer)
      end
    end

    def inject!
      eval(described_class::INJECTION_CODE) # rubocop:disable Security/Eval
    end

    it "subscribes, assigns monotonic seq, and truncates SQL at save time" do
      inject!
      buf = ::DebugMcpNotificationsBuffer
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") {}
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "x" * 5000) {}
      expect(buf.buffer.map { |e| e[:seq] }).to eq([1, 2])
      expect(buf.fetch_last(1).first[:seq]).to eq(2)
      expect(buf.fetch_after_seq(1).map { |e| e[:seq] }).to eq([2])
      stored = buf.buffer.last[:data][:sql]
      expect(stored.length).to be <= (DebugMcp::NotificationsSubscriber::STORE_SQL_MAX + 40)
      expect(stored).to include("truncated")
    end

    it "recovers subscriptions after uninstall when re-injected (poison recovery)" do
      inject!
      ::DebugMcpNotificationsBuffer.uninstall
      expect(::DebugMcpNotificationsBuffer.subscriptions).to be_empty
      inject! # module already defined; .install runs outside the guard
      expect(::DebugMcpNotificationsBuffer.subscriptions).not_to be_empty
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "after recovery") {}
      expect(::DebugMcpNotificationsBuffer.buffer.last[:data][:sql]).to eq("after recovery")
    end

    it "never blocks on read when a stopped thread holds the mutex" do
      require "timeout"
      inject!
      buf = ::DebugMcpNotificationsBuffer
      mutex = buf.instance_variable_get(:@mutex)
      ready = Queue.new
      release = Queue.new
      holder = Thread.new { mutex.synchronize { ready << true; release.pop } }
      ready.pop
      begin
        expect { Timeout.timeout(2) { buf.fetch_last(5) } }.not_to raise_error
      ensure
        release << true
        holder.join
      end
    end
  end
end
