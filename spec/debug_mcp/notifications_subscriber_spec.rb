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
    end
  end

  describe ".fetch_by_request_id" do
    it "returns empty array when request_id is nil" do
      expect(client).not_to receive(:send_command)
      expect(described_class.fetch_by_request_id(client, nil)).to eq([])
    end

    it "parses a JSON array response into symbolized hashes" do
      json_line = '[{"name":"sql.active_record","timestamp":1.0,"duration_ms":2.5,"request_id":"abc","data":{"sql":"SELECT 1"}}]'
      allow(client).to receive(:send_command).and_return("=> nil\n#{json_line}\n")
      result = described_class.fetch_by_request_id(client, "abc")
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
      expect(result.first[:name]).to eq("sql.active_record")
      expect(result.first[:data][:sql]).to eq("SELECT 1")
    end

    it "returns empty array when no JSON line is present" do
      allow(client).to receive(:send_command).and_return("=> nil\n")
      expect(described_class.fetch_by_request_id(client, "abc")).to eq([])
    end

    it "returns empty array when response is malformed JSON" do
      allow(client).to receive(:send_command).and_return("[not valid json]\n")
      expect(described_class.fetch_by_request_id(client, "abc")).to eq([])
    end

    it "returns empty array on DebugMcp::Error" do
      allow(client).to receive(:send_command).and_raise(DebugMcp::Error.new("boom"))
      expect(described_class.fetch_by_request_id(client, "abc")).to eq([])
    end
  end

  describe ".fetch_since" do
    it "sends timestamp as float and parses the JSON response" do
      allow(client).to receive(:send_command) do |cmd|
        expect(cmd).to include("123.45")
        '[{"name":"render_template.action_view"}]'
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
  end
end
