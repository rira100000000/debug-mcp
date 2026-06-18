# frozen_string_literal: true

RSpec.describe DebugMcp::Tools::RailsInfo do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      # Rails detection
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')
      # Default fallback for Base64 eval scripts (DB and routes sections)
      allow(client).to receive(:send_command)
        .with(kind_of(String), timeout: 15)
        .and_return("=> nil")
    end

    it "displays Rails application info" do
      stub_app_basics(client)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("=== Rails Application ===")
      expect(text).to include("App: MyApp")
      expect(text).to include("Rails: 7.1.3 (development)")
      expect(text).to include("Ruby: 3.3.0")
      expect(text).to include("Root: /home/user/myapp")
    end

    it "displays database configuration via Base64 script" do
      stub_app_basics(client)
      stub_info_scripts(client,
        db: "Database:\n  adapter: sqlite3\n  database: storage/development.sqlite3")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Database:")
      expect(text).to include("adapter: sqlite3")
      expect(text).to include("database: storage/development.sqlite3")
    end

    it "masks sensitive database fields" do
      stub_app_basics(client)
      stub_info_scripts(client,
        db: "Database:\n  adapter: postgresql\n  password: [FILTERED]\n  database: myapp_dev")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("password: [FILTERED]")
      expect(text).not_to include("secret123")
    end

    it "displays route count summary" do
      stub_app_basics(client)
      stub_info_scripts(client,
        routes: "Routes: 15 defined (use 'rails_routes' for details)")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Routes: 15 defined")
      expect(text).to include("rails_routes")
    end

    it "displays the observability section with delivery method, queue adapter and cache store" do
      stub_app_basics(client)
      allow(client).to receive(:send_command)
        .with("p (defined?(ActionMailer::Base) ? ActionMailer::Base.delivery_method : :no_action_mailer)")
        .and_return("=> :test")
      allow(client).to receive(:send_command)
        .with(/queue_adapter_name/)
        .and_return("=> :inline")
      allow(client).to receive(:send_command)
        .with(/Rails\.cache\.class\.name/)
        .and_return('=> "ActiveSupport::Cache::MemoryStore"')

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("=== Observability ===")
      expect(text).to include("ActionMailer delivery_method: :test")
      expect(text).to include("ActiveJob queue_adapter: :inline")
      expect(text).to include("Cache store: ActiveSupport::Cache::MemoryStore")
      expect(text).to include("rails_mail_deliveries")
    end

    it "handles non-Rails process" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: Not a Rails application")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: No session")
    end

    it "handles partial failures gracefully" do
      stub_app_basics(client)
      # DB and routes scripts fail
      allow(client).to receive(:send_command)
        .with(kind_of(String), timeout: 15)
        .and_raise(DebugMcp::TimeoutError, "timeout")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      # Should still show app info even if DB/routes sections fail
      expect(text).to include("App: MyApp")
      # Unavailable sections show a note instead of being silently dropped
      expect(text).to include("Database:\n  (unavailable)")
      expect(text).to include("Routes:\n  (unavailable)")
    end

    it "shows trap context hint when sections are unavailable" do
      stub_app_basics(client)
      allow(client).to receive(:send_command)
        .with(kind_of(String), timeout: 15)
        .and_return("=> nil")
      allow(client).to receive(:in_trap_context?).and_return(true)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("trap context")
      expect(text).to include("trigger_request")
    end

    context "database.yml fallback" do
      before { stub_app_basics(client) }

      it "falls back to database.yml when Base64 script fails" do
        # Base64 script fails
        allow(client).to receive(:send_command)
          .with(kind_of(String), timeout: 15)
          .and_raise(DebugMcp::TimeoutError, "timeout")

        # database.yml fallback
        yaml_content = <<~YAML
          development:
            adapter: postgresql
            database: myapp_dev
            host: localhost
        YAML
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return('=> "/home/user/myapp"')
        allow(client).to receive(:send_command)
          .with("p Rails.env")
          .and_return('=> "development"')
        allow(client).to receive(:send_command)
          .with('p File.read("/home/user/myapp/config/database.yml")')
          .and_return("=> #{yaml_content.inspect}")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Database: (from database.yml)")
        expect(text).to include("adapter: postgresql")
        expect(text).to include("database: myapp_dev")
      end

      it "handles ERB tags in database.yml" do
        allow(client).to receive(:send_command)
          .with(kind_of(String), timeout: 15)
          .and_return("=> nil")

        yaml_content = <<~YAML
          development:
            adapter: postgresql
            database: <%= ENV['DATABASE_NAME'] %>
            password: <%= ENV['DATABASE_PASSWORD'] %>
        YAML
        allow(client).to receive(:send_command)
          .with('p File.read("/home/user/myapp/config/database.yml")')
          .and_return("=> #{yaml_content.inspect}")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Database: (from database.yml)")
        expect(text).to include("adapter: postgresql")
        expect(text).to include("database: DYNAMIC")
        expect(text).to include("password: [FILTERED]")
      end

      it "falls back to database.yml when Base64 script returns error string" do
        # Base64 script runs successfully but returns an error string
        # (e.g., ThreadError in trap context caught by the script's rescue)
        stub_info_scripts(client,
          db: "Database:\n  Error: can't be called from trap context")

        yaml_content = <<~YAML
          development:
            adapter: sqlite3
            database: storage/dev.sqlite3
        YAML
        allow(client).to receive(:send_command)
          .with('p File.read("/home/user/myapp/config/database.yml")')
          .and_return("=> #{yaml_content.inspect}")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Database: (from database.yml)")
        expect(text).to include("adapter: sqlite3")
        expect(text).not_to include("Error: can't be called")
      end

      it "shows unavailable when database.yml fallback also fails" do
        allow(client).to receive(:send_command)
          .with(kind_of(String), timeout: 15)
          .and_return("=> nil")
        # File.read fails too
        allow(client).to receive(:send_command)
          .with('p File.read("/home/user/myapp/config/database.yml")')
          .and_return("=> nil")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Database:\n  (unavailable)")
      end
    end
  end

  private

  def stub_app_basics(client)
    allow(client).to receive(:send_command)
      .with("p Rails.application.class.module_parent_name")
      .and_return('=> "MyApp"')
    allow(client).to receive(:send_command)
      .with("p Rails::VERSION::STRING")
      .and_return('=> "7.1.3"')
    allow(client).to receive(:send_command)
      .with("p Rails.env")
      .and_return('=> "development"')
    allow(client).to receive(:send_command)
      .with("p RUBY_VERSION")
      .and_return('=> "3.3.0"')
    allow(client).to receive(:send_command)
      .with("p Rails.root.to_s")
      .and_return('=> "/home/user/myapp"')
  end

  # Stub Base64 info scripts by decoding the Base64 in the command to route responses.
  def stub_info_scripts(client, db: nil, routes: nil)
    allow(client).to receive(:send_command)
      .with(kind_of(String), timeout: 15) do |cmd, **_|
        encoded = cmd[/decode64\('([^']+)'\)/, 1]
        if encoded
          script = Base64.decode64(encoded)
          if db && script.include?("ActiveRecord")
            "#{db}\n=> nil"
          elsif routes && script.include?("routes")
            "#{routes}\n=> nil"
          else
            "=> nil"
          end
        else
          "=> nil"
        end
      end
  end
end
