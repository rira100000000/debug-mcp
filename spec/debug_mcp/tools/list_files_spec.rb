# frozen_string_literal: true

require "tmpdir"

RSpec.describe DebugMcp::Tools::ListFiles do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    let(:tmpdir) do
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")
      File.write(File.join(dir, "app", "models", "user.rb"), "class User; end\n")
      File.write(File.join(dir, "config", "routes.rb"), "# routes\n")
      File.write(File.join(dir, "config", "database.yml"), "# db config\n")
      dir
    end

    after { FileUtils.rm_rf(tmpdir) }

    it "lists immediate children of a directory" do
      response = described_class.call(path: tmpdir, server_context: server_context)
      text = response_text(response)

      expect(text).to include("[dir]")
      expect(text).to include("[file]")
      expect(text).to include("Gemfile")
      expect(text).to include("app")
      expect(text).to include("config")
    end

    it "uses the requested session when session_id is provided" do
      allow(manager).to receive(:client).with("custom-session").and_return(client)
      allow(manager).to receive(:client).with(nil).and_return(nil)

      response = described_class.call(
        path: tmpdir,
        session_id: "custom-session",
        server_context: server_context,
      )
      text = response_text(response)

      expect(text).to include("Gemfile")
      expect(manager).to have_received(:client).with("custom-session")
    end

    it "includes entry count in header" do
      response = described_class.call(path: tmpdir, server_context: server_context)
      text = response_text(response)

      expect(text).to include("3 entries")
    end

    it "filters with glob pattern" do
      response = described_class.call(
        path: tmpdir,
        pattern: "**/*.rb",
        server_context: server_context,
      )
      text = response_text(response)

      expect(text).to include("user.rb")
      expect(text).to include("routes.rb")
      expect(text).not_to include("database.yml")
      expect(text).not_to include("Gemfile")
      expect(text).to include("matching '**/*.rb'")
    end

    it "filters with non-recursive glob pattern" do
      response = described_class.call(
        path: File.join(tmpdir, "config"),
        pattern: "*.yml",
        server_context: server_context,
      )
      text = response_text(response)

      expect(text).to include("database.yml")
      expect(text).not_to include("routes.rb")
    end

    it "returns error for non-existent directory" do
      response = described_class.call(
        path: "/nonexistent/directory",
        server_context: server_context,
      )
      text = response_text(response)

      expect(text).to include("Error: Directory not found")
    end

    it "returns empty list for empty directory" do
      empty_dir = Dir.mktmpdir
      response = described_class.call(path: empty_dir, server_context: server_context)
      text = response_text(response)

      expect(text).to include("0 entries")
    ensure
      FileUtils.rm_rf(empty_dir)
    end

    context "remote listing (Docker/TCP)" do
      let(:remote_client) { build_mock_client(remote: true) }
      let(:remote_manager) { build_mock_manager(client: remote_client) }
      let(:remote_context) { { session_manager: remote_manager } }

      it "lists directory via debug session for remote connections" do
        allow(remote_client).to receive(:send_command)
          .with("p Dir.exist?(\"/app\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with(/p Dir\.children.*\.join/)
          .and_return('=> "d:/app/config\nf:/app/Gemfile"')

        response = described_class.call(path: "/app", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("[remote]")
        expect(text).to include("[dir]")
        expect(text).to include("[file]")
        expect(text).to include("2 entries")
      end

      it "returns error when remote directory not found" do
        allow(remote_client).to receive(:send_command)
          .with("p Dir.exist?(\"/missing\")")
          .and_return('=> "false"')

        response = described_class.call(path: "/missing", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("Error: Directory not found on remote process")
      end

      it "uses glob pattern on remote" do
        allow(remote_client).to receive(:send_command)
          .with("p Dir.exist?(\"/app\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with(/p Dir\.glob.*\.join/)
          .and_return('=> "f:/app/models/user.rb\nf:/app/config/routes.rb"')

        response = described_class.call(
          path: "/app",
          pattern: "**/*.rb",
          server_context: remote_context,
        )
        text = response_text(response)

        expect(text).to include("[remote]")
        expect(text).to include("user.rb")
        expect(text).to include("routes.rb")
      end

      it "resolves relative paths via remote cwd" do
        allow(remote_client).to receive(:send_command)
          .with("p Dir.pwd")
          .and_return('=> "/app"')
        allow(remote_client).to receive(:send_command)
          .with("p Dir.exist?(\"/app/config\")")
          .and_return('=> "true"')
        allow(remote_client).to receive(:send_command)
          .with(/p Dir\.children.*\.join/)
          .and_return('=> "f:/app/config/routes.rb"')

        response = described_class.call(path: "config", server_context: remote_context)
        text = response_text(response)

        expect(text).to include("[remote]")
        expect(text).to include("/app/config")
      end
    end
  end

  describe "MAX_ENTRIES" do
    it "is 500" do
      expect(DebugMcp::Tools::ListFiles::MAX_ENTRIES).to eq(500)
    end
  end
end
