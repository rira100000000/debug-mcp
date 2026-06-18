# frozen_string_literal: true

RSpec.describe DebugMcp::RailsHelper do
  let(:client) { build_mock_client }

  describe ".require_rails!" do
    it "succeeds when Rails is defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')

      expect { described_class.require_rails!(client) }.not_to raise_error
    end

    it "raises SessionError when Rails is not defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      expect { described_class.require_rails!(client) }.to raise_error(
        DebugMcp::SessionError, /Not a Rails application/,
      )
    end
  end

  describe ".rails?" do
    it "returns true when Rails is defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')

      expect(described_class.rails?(client)).to be true
    end

    it "returns false when Rails is not defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      expect(described_class.rails?(client)).to be false
    end

    it "returns false on error" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_raise(
        DebugMcp::ConnectionError, "lost",
      )

      expect(described_class.rails?(client)).to be false
    end
  end

  describe ".log_file_path" do
    it "returns log file path for Rails app" do
      allow(client).to receive(:send_command)
        .with("p Rails.root.to_s")
        .and_return('=> "/app"')
      allow(client).to receive(:send_command)
        .with("p Rails.env")
        .and_return('=> "development"')

      expect(described_class.log_file_path(client)).to eq("/app/log/development.log")
    end

    it "returns nil when root is unavailable" do
      allow(client).to receive(:send_command)
        .with("p Rails.root.to_s")
        .and_return("=> nil")

      expect(described_class.log_file_path(client)).to be_nil
    end

    it "returns nil on error" do
      allow(client).to receive(:send_command).and_raise(DebugMcp::ConnectionError, "lost")

      expect(described_class.log_file_path(client)).to be_nil
    end
  end

  describe ".observability_probe" do
    it "returns delivery method, queue adapter and cache store" do
      allow(client).to receive(:send_command).with(/ActionMailer::Base/).and_return("=> :test")
      allow(client).to receive(:send_command).with(/queue_adapter_name/).and_return("=> :inline")
      allow(client).to receive(:send_command).with(/Rails\.cache/).and_return('=> "ActiveSupport::Cache::NullStore"')

      probe = described_class.observability_probe(client)
      expect(probe[:delivery_method]).to eq(":test")
      expect(probe[:queue_adapter]).to eq(":inline")
      expect(probe[:cache_store]).to eq("ActiveSupport::Cache::NullStore")
    end

    it "falls back to (unavailable) when a probe cannot be evaluated" do
      allow(client).to receive(:send_command).and_return("=> nil")

      probe = described_class.observability_probe(client)
      expect(probe.values).to all(eq("(unavailable)"))
    end
  end
end
