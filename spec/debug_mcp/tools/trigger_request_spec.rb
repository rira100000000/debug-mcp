# frozen_string_literal: true

RSpec.describe DebugMcp::Tools::TriggerRequest do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  # Shared HTTP mocking helpers
  let(:mock_http) do
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    http
  end

  def stub_http_response(code: "200", message: "OK", body: '{"status": "ok"}',
                         headers: { "content-type" => ["application/json"] }, request_class: Net::HTTP::Get)
    stub_request = instance_double(request_class)
    allow(stub_request).to receive(:[]=)
    allow(stub_request).to receive(:body=)
    allow(request_class).to receive(:new).and_return(stub_request)

    body_str = body.dup.force_encoding("UTF-8")
    mock_response = instance_double(Net::HTTPResponse,
      code: code,
      message: message,
      to_hash: headers)
    allow(mock_response).to receive(:body).and_return(body_str)
    allow(mock_http).to receive(:request).and_return(mock_response)
    allow(Net::HTTP).to receive(:new).and_return(mock_http)

    mock_response
  end

  describe ".call" do
    it "sends HTTP request and returns response without debug session" do
      allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")
      stub_http_response

      response = described_class.call(
        method: "GET",
        url: "http://localhost:3000/api/status",
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("200")
    end

    context "auto-resume behavior" do
      it "resumes paused process and waits for breakpoint" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  app/controllers/users_controller.rb:10 (line)\n=> 10| @user = User.find(params[:id])",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Breakpoint hit")
        expect(text).to include("users_controller.rb:10")
        expect(text).to include("request sent")
        expect(text).to include("continue_execution")
        expect(text).to include("see the HTTP response")
      end

      it "uses wait_for_breakpoint when process is already running" do
        stub_http_response

        allow(client).to receive(:paused).and_return(false) # process running
        allow(client).to receive(:wait_for_breakpoint).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  app/controllers/users_controller.rb:10 (line)",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Breakpoint hit")
        expect(client).to have_received(:wait_for_breakpoint)
      end

      it "returns HTTP response when interrupted (no breakpoint hit)" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("No breakpoint hit")
        expect(text).to include("200")
      end

      it "shows re-paused hint when auto_repause succeeds after no breakpoint hit" do
        stub_http_response

        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:ensure_paused).and_return("")
        allow(not_paused_client).to receive(:continue_and_wait).and_return({
          type: :interrupted,
          output: "",
        })
        allow(not_paused_client).to receive(:auto_repause!) do
          allow(not_paused_client).to receive(:paused).and_return(true)
          true
        end

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("No breakpoint hit")
        expect(text).to include("re-paused")
        expect(text).to include("evaluate code")
        expect(text).to include("200")
      end

      it "shows running hint when auto_repause fails after no breakpoint hit" do
        stub_http_response

        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:ensure_paused).and_return("")
        allow(not_paused_client).to receive(:continue_and_wait).and_return({
          type: :interrupted,
          output: "",
        })
        allow(not_paused_client).to receive(:auto_repause!).and_raise(
          DebugMcp::SessionError, "could not be interrupted"
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("No breakpoint hit")
        expect(text).to include("process is now running")
        expect(text).to include("200")
      end

      it "returns HTTP response when continue times out" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        # HTTP completed, so we show the response even though continue timed out
        expect(text).to include("No breakpoint hit")
        expect(text).to include("200")
      end

      it "shows diagnostic message when HTTP also fails" do
        allow(Net::HTTP).to receive(:new).and_raise(StandardError, "connection refused")

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Request error")
        expect(text).to include("connection refused")
      end

      it "shows breakpoint diagnostics on timeout" do
        # Use short join timeout to avoid slow test
        stub_const("DebugMcp::Tools::TriggerRequest::HTTP_JOIN_TIMEOUT", 0.1)

        # Block HTTP thread so http_holder[:done] stays false
        request_barrier = Queue.new
        stub_http_response
        allow(mock_http).to receive(:request) { request_barrier.pop }

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("#1  BP - Line  app/controllers/users_controller.rb:10 (line)")

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        request_barrier << nil # Release HTTP thread

        text = response_text(response)

        expect(text).to include("No breakpoint was hit")
        expect(text).to include("Current breakpoints:")
        expect(text).to include("users_controller.rb:10")
        expect(text).to include("Verify that the breakpoint file paths")
      end

      it "shows running-process guidance when not paused on timeout" do
        stub_const("DebugMcp::Tools::TriggerRequest::HTTP_JOIN_TIMEOUT", 0.1)

        request_barrier = Queue.new
        stub_http_response
        allow(mock_http).to receive(:request) { request_barrier.pop }

        # Process is not paused (e.g., after continue timeout)
        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:wait_for_breakpoint).and_return({
          type: :timeout,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        request_barrier << nil

        text = response_text(response)

        expect(text).to include("process is running")
        expect(text).to include("set_breakpoint")
        expect(text).to include("trigger_request")
        expect(text).to include("disconnect")
        expect(text).not_to include("get_context")
      end

      it "attempts auto_repause! recovery on double timeout" do
        stub_const("DebugMcp::Tools::TriggerRequest::HTTP_JOIN_TIMEOUT", 0.1)

        request_barrier = Queue.new
        stub_http_response
        allow(mock_http).to receive(:request) { request_barrier.pop }

        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:wait_for_breakpoint).and_return({
          type: :timeout,
          output: "",
        })
        allow(not_paused_client).to receive(:auto_repause!).and_return(true)

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        request_barrier << nil

        text = response_text(response)

        expect(not_paused_client).to have_received(:auto_repause!).at_least(:once)
        expect(text).to include("Recovery: Successfully re-paused")
      end

      it "shows normal diagnostics when auto_repause! recovery fails" do
        stub_const("DebugMcp::Tools::TriggerRequest::HTTP_JOIN_TIMEOUT", 0.1)

        request_barrier = Queue.new
        stub_http_response
        allow(mock_http).to receive(:request) { request_barrier.pop }

        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:wait_for_breakpoint).and_return({
          type: :timeout,
          output: "",
        })
        allow(not_paused_client).to receive(:auto_repause!).and_raise(
          DebugMcp::SessionError, "could not be interrupted"
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        request_barrier << nil

        text = response_text(response)

        expect(text).not_to include("Recovery:")
        expect(text).to include("No breakpoint was hit")
      end

      it "skips recovery when process is already paused on timeout" do
        stub_const("DebugMcp::Tools::TriggerRequest::HTTP_JOIN_TIMEOUT", 0.1)

        request_barrier = Queue.new
        stub_http_response
        allow(mock_http).to receive(:request) { request_barrier.pop }

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("No breakpoints")

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        request_barrier << nil

        text = response_text(response)

        # auto_repause! should not be called again in recovery (only initial call)
        expect(text).not_to include("Recovery:")
      end

      it "shows no-breakpoints hint on timeout when none set" do
        stub_const("DebugMcp::Tools::TriggerRequest::HTTP_JOIN_TIMEOUT", 0.1)

        request_barrier = Queue.new
        stub_http_response
        allow(mock_http).to receive(:request) { request_barrier.pop }

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("No breakpoints")

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        request_barrier << nil

        text = response_text(response)

        expect(text).to include("Current breakpoints: (none set)")
        expect(text).to include("set_breakpoint")
      end

      it "handles pending breakpoint output from ensure_paused" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return(
          "Stop by #2  BP - Line  app/models/user.rb:5 (line)\n=> 5| validates :email",
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Breakpoint hit")
        expect(text).to include("user.rb:5")
        # Should NOT call continue_and_wait since breakpoint was already in pending output
        expect(client).not_to have_received(:continue_and_wait)
      end

      it "annotates breakpoint stop events" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  f.rb:10 (return)",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Stop event (return)")
      end

      it "cleans up one-shot breakpoints on hit" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #3  BP - Line  f.rb:5 (line)",
        })

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        expect(client).to have_received(:cleanup_one_shot_breakpoints)
      end

      it "handles debug session error gracefully" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_raise(
          DebugMcp::ConnectionError, "Connection lost",
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Debug session lost")
      end

      it "calls auto_repause! before checking paused state" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        expect(client).to have_received(:auto_repause!)
      end

      it "proceeds normally when auto_repause! fails" do
        stub_http_response

        allow(client).to receive(:auto_repause!).and_raise(
          DebugMcp::ConnectionError, "repause failed",
        )
        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        # Should still succeed with HTTP response
        expect(text).to include("200")
      end
    end

    context "Content-Type auto-detection" do
      before do
        allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")
      end

      it "auto-detects JSON body" do
        stub_request = instance_double(Net::HTTP::Post)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Post).to receive(:new).and_return(stub_request)

        body_str = '{"ok": true}'.dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "201", message: "Created",
          to_hash: { "content-type" => ["application/json"] })
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          server_context: server_context,
        )

        expect(stub_request).to have_received(:[]=).with("Content-Type", "application/json")
      end

      it "auto-detects form-urlencoded body" do
        stub_request = instance_double(Net::HTTP::Post)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Post).to receive(:new).and_return(stub_request)

        body_str = "ok".dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "200", message: "OK",
          to_hash: { "content-type" => ["text/html"] })
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: "name=Alice&email=alice@example.com",
          server_context: server_context,
        )

        expect(stub_request).to have_received(:[]=).with("Content-Type", "application/x-www-form-urlencoded")
      end

      it "does not override explicit Content-Type" do
        stub_request = instance_double(Net::HTTP::Post)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Post).to receive(:new).and_return(stub_request)

        body_str = "ok".dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "200", message: "OK",
          to_hash: {})
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/upload",
          headers: { "Content-Type" => "multipart/form-data" },
          body: '{"data": true}',
          server_context: server_context,
        )

        # Should NOT set Content-Type to application/json since explicit header provided
        expect(stub_request).to have_received(:[]=).with("Content-Type", "multipart/form-data")
      end
    end

    context "cookie management" do
      it "sends cookies as Cookie header" do
        allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")

        stub_request = instance_double(Net::HTTP::Get)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Get).to receive(:new).and_return(stub_request)

        body_str = "ok".dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "200", message: "OK",
          to_hash: {})
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/dashboard",
          cookies: { "_session_id" => "abc123", "user_id" => "42" },
          server_context: server_context,
        )

        expect(stub_request).to have_received(:[]=).with("Cookie", "_session_id=abc123; user_id=42")
      end

      it "displays Set-Cookie from response" do
        allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")
        stub_http_response(
          headers: {
            "content-type" => ["text/html"],
            "set-cookie" => ["_session_id=xyz789; path=/"],
          },
          body: "<html></html>",
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/login",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Set-Cookie:")
        expect(text).to include("_session_id=xyz789")
      end
    end

    context "CSRF handling" do
      it "disables and restores CSRF when breakpoint is hit (process paused)" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
          .and_return("=> true")

        stub_http_response(request_class: Net::HTTP::Post)

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  app/controllers/users_controller.rb:10 (line)",
        })

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          server_context: server_context,
        )

        expect(client).to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
        expect(client).to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
      end

      it "does not restore CSRF when process is not paused (interrupted)" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")

        stub_http_response(request_class: Net::HTTP::Post)

        # After continue_and_wait returns :interrupted, process is running (not paused)
        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(not_paused_client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(not_paused_client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")
        allow(not_paused_client).to receive(:ensure_paused).and_return("")
        allow(not_paused_client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          server_context: server_context,
        )

        # CSRF should NOT be restored because process is running
        expect(not_paused_client).not_to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
      end

      it "does not disable CSRF for GET requests" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        expect(client).not_to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
      end

      it "skips CSRF when skip_csrf is false" do
        stub_http_response(request_class: Net::HTTP::Post)

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          skip_csrf: false,
          server_context: server_context,
        )

        expect(client).not_to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
      end

      it "restores CSRF on error when client is still paused" do
        # Client stays paused (e.g., error before continue was called)
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
          .and_return("=> true")

        allow(client).to receive(:ensure_paused).and_raise(
          DebugMcp::ConnectionError, "Connection lost",
        )

        # Make HTTP request fail too
        allow(Net::HTTP).to receive(:new).and_raise(StandardError, "connection refused")

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: "{}",
          server_context: server_context,
        )

        # CSRF restored because client.paused is true (error before continue)
        expect(client).to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
      end
    end

    context "response formatting" do
      before do
        allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")
      end

      it "pretty-prints JSON responses" do
        stub_http_response(body: '{"name":"Alice","age":30}')

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        # JSON.pretty_generate adds indentation
        expect(text).to include("\"name\": \"Alice\"")
        expect(text).to include("\"age\": 30")
      end

      it "summarizes long HTML responses" do
        long_html = "<html><head><title>My Page</title></head><body>#{"x" * 1500}</body></html>"
        stub_http_response(
          body: long_html,
          headers: { "content-type" => ["text/html; charset=utf-8"] },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Content-Length:")
        expect(text).to include("Title: My Page")
        expect(text).to include("Body text (first 500 chars):")
        expect(text).not_to include("<html>")
        expect(text).not_to include("<body>")
      end

      it "extracts title from HTML" do
        html = "<html><head><title>Dashboard</title></head><body><p>Hello</p></body></html>"
        stub_http_response(
          body: html,
          headers: { "content-type" => ["text/html"] },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Title: Dashboard")
        expect(text).to include("Body text:\nDashboard Hello")
      end

      it "strips script and style tags from HTML" do
        html = '<html><head><style>body { color: red; }</style></head>' \
               '<body><script>alert("xss")</script><p>Visible</p></body></html>'
        stub_http_response(
          body: html,
          headers: { "content-type" => ["text/html"] },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Body text:\nVisible")
        expect(text).not_to include("alert")
        expect(text).not_to include("color: red")
      end

      it "converts HTML entities" do
        html = "<html><body>&amp; &lt;tag&gt; &quot;quoted&quot;</body></html>"
        stub_http_response(
          body: html,
          headers: { "content-type" => ["text/html"] },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include('& <tag> "quoted"')
      end

      it "handles HTML with no text content" do
        html = "<html><head></head><body><img src='logo.png'></body></html>"
        stub_http_response(
          body: html,
          headers: { "content-type" => ["text/html"] },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Body: (no text content)")
      end

      it "shows redirect location" do
        stub_http_response(
          code: "302",
          message: "Found",
          body: "",
          headers: {
            "location" => ["http://localhost:3000/login"],
            "content-type" => ["text/html"],
          },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/dashboard",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("302")
        expect(text).to include("Location: http://localhost:3000/login")
      end

      it "handles empty body" do
        stub_http_response(
          code: "204",
          message: "No Content",
          body: "",
          headers: {},
        )

        response = described_class.call(
          method: "DELETE",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("204")
        expect(text).to include("(empty body)")
      end
    end

    context "Rails log capture" do
      let(:rails_root) { Dir.mktmpdir }
      let(:log_dir) { File.join(rails_root, "log") }
      let(:log_file) { File.join(log_dir, "development.log") }

      before { FileUtils.mkdir_p(log_dir) }
      after { FileUtils.remove_entry(rails_root) }

      it "appends server log to response when available" do
        # Pre-fill log file with existing content
        File.write(log_file, "old log line\n")

        # Set up Rails detection for log capture
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return("=> \"#{rails_root}\"")
        allow(client).to receive(:send_command)
          .with("p Rails.env")
          .and_return('=> "development"')

        stub_http_response

        # Simulate log being written during request
        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait) do
          File.write(log_file, "old log line\nStarted GET /users\nCompleted 200 OK\n")
          { type: :interrupted, output: "" }
        end

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("--- Server Log ---")
        expect(text).to include("Started GET /users")
        expect(text).to include("Completed 200 OK")
        expect(text).not_to include("old log line")
      end

      it "skips log section when no new log entries" do
        File.write(log_file, "existing log\n")

        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return("=> \"#{rails_root}\"")
        allow(client).to receive(:send_command)
          .with("p Rails.env")
          .and_return('=> "development"')

        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).not_to include("--- Server Log ---")
      end

      it "skips log capture for non-Rails processes" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return("=> nil")

        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).not_to include("--- Server Log ---")
      end
    end
  end

  describe ".resolve_event_limits (private)" do
    it "returns DEFAULT_LIMITS when overrides is nil" do
      result = described_class.send(:resolve_event_limits, nil)
      expect(result).to eq(DebugMcp::EventFormatter::DEFAULT_LIMITS)
    end

    it "returns DEFAULT_LIMITS when overrides is empty" do
      result = described_class.send(:resolve_event_limits, {})
      expect(result).to eq(DebugMcp::EventFormatter::DEFAULT_LIMITS)
    end

    it "merges symbol-key overrides into defaults" do
      result = described_class.send(:resolve_event_limits, { sql: 100 })
      expect(result[:sql]).to eq(100)
      expect(result[:render]).to eq(20)
    end

    it "accepts string keys as well as symbols" do
      result = described_class.send(:resolve_event_limits, { "sql" => 5, "render" => 3 })
      expect(result[:sql]).to eq(5)
      expect(result[:render]).to eq(3)
    end

    it "allows nil to disable a limit" do
      result = described_class.send(:resolve_event_limits, { sql: nil })
      expect(result[:sql]).to be_nil
    end

    it "coerces stringified integers" do
      result = described_class.send(:resolve_event_limits, { "sql" => "42" })
      expect(result[:sql]).to eq(42)
    end

    it "ignores unknown keys" do
      result = described_class.send(:resolve_event_limits, { bogus: 1 })
      expect(result).not_to have_key(:bogus)
    end

    it "preserves the default for keys whose override is unparseable" do
      result = described_class.send(:resolve_event_limits, { "sql" => "not-a-number" })
      expect(result[:sql]).to eq(DebugMcp::EventFormatter::DEFAULT_LIMITS[:sql])
    end
  end

  describe ".call with event_limits / include_debug_eval" do
    let(:events) do
      [
        { name: "process_action.action_controller", duration_ms: 50.0, source: :request,
          data: { controller: "C", action: "a", method: "GET", path: "/", status: 200 } },
        { name: "sql.active_record", duration_ms: 1.0, source: :request,
          data: { sql: "SELECT 1", query_name: "App", binds: [], cached: false } },
        { name: "sql.active_record", duration_ms: 0.5, source: :debug_eval,
          data: { sql: "PRAGMA table_xinfo(\"users\")", query_name: "SCHEMA", binds: [], cached: false } },
      ]
    end

    before do
      allow(DebugMcp::RailsHelper).to receive(:rails?).and_return(true)
      allow(DebugMcp::NotificationsSubscriber).to receive(:install).and_return(true)
      allow(DebugMcp::NotificationsSubscriber).to receive(:fetch_by_request_id).and_return(events)
      allow(client).to receive(:continue_and_wait).and_return({ type: :interrupted, output: "" })
      allow(client).to receive(:ensure_paused).and_return("")
      stub_http_response
    end

    it "hides :debug_eval events by default" do
      response = described_class.call(
        method: "GET", url: "http://localhost:3000/",
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("## SQL (1 query)")
      expect(text).not_to include("PRAGMA")
    end

    it "shows :debug_eval events when include_debug_eval: true" do
      response = described_class.call(
        method: "GET", url: "http://localhost:3000/",
        include_debug_eval: true,
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("## SQL (2 queries)")
      expect(text).to include("PRAGMA")
    end

    it "applies user-supplied event_limits to truncate sections" do
      bulky = (1..50).map do |i|
        { name: "sql.active_record", duration_ms: 1.0, source: :request,
          data: { sql: "SELECT #{i}", query_name: "", binds: [], cached: false } }
      end
      allow(DebugMcp::NotificationsSubscriber).to receive(:fetch_by_request_id).and_return(bulky)

      response = described_class.call(
        method: "GET", url: "http://localhost:3000/",
        event_limits: { "sql" => 5 },
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("## SQL (50 queries)")
      expect(text).to include("... and 45 more (limit=5)")
    end
  end

  describe "DEFAULT_TIMEOUT" do
    it "is 30" do
      expect(DebugMcp::Tools::TriggerRequest::DEFAULT_TIMEOUT).to eq(30)
    end
  end

  describe "HTTP_BREAKPOINT_TIMEOUT" do
    it "is 300 (5 minutes) to survive investigation at breakpoints" do
      expect(DebugMcp::Tools::TriggerRequest::HTTP_BREAKPOINT_TIMEOUT).to eq(300)
    end
  end
end
