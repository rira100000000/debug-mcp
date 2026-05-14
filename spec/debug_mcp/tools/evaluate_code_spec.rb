# frozen_string_literal: true

RSpec.describe DebugMcp::Tools::EvaluateCode do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      # Default: stdout redirect succeeds, no error, empty captured stdout
      allow(client).to receive(:send_command).and_return("")
    end

    it "evaluates code and returns result" do
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

      response = described_class.call(code: "1 + 1", server_context: server_context)
      text = response_text(response)
      expect(text).to include("42")
    end

    it "handles evaluation error" do
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> nil")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return(
        '=> "NameError: undefined local variable \'x\'"'
      )
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

      response = described_class.call(code: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error:")
      expect(text).to include("NameError")
    end

    it "captures stdout output" do
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> nil")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return(
        '=> "hello world\n"'
      )

      response = described_class.call(code: 'puts "hello world"', server_context: server_context)
      text = response_text(response)
      expect(text).to include("Captured stdout:")
      expect(text).to include("hello world")
    end

    it "suppresses captured stdout when it duplicates the return value (pp output)" do
      # pp(5) writes "5\n" to $stdout AND returns => 5 — same content, show only once
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 5")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return(
        '=> "5\n"'
      )

      response = described_class.call(code: "Order.completed.count", server_context: server_context)
      text = response_text(response)
      expect(text).to include("5")
      expect(text).not_to include("Captured stdout")
      expect(text).not_to include("Return value")
    end

    it "shows both sections when captured stdout has additional content" do
      # puts "debug info"; 42 → captured has "debug info\n42\n", return value is "=> 42"
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return(
        '=> "debug info\n42\n"'
      )

      response = described_class.call(code: 'puts "debug info"; 42', server_context: server_context)
      text = response_text(response)
      expect(text).to include("Return value:")
      expect(text).to include("Captured stdout:")
      expect(text).to include("debug info")
    end

    it "propagates session error from client lookup" do
      allow(manager).to receive(:client).and_raise(
        DebugMcp::SessionError, "No active session"
      )

      # EvaluateCode's client lookup is outside the begin/rescue block,
      # so the SessionError propagates to the MCP framework.
      expect {
        described_class.call(code: "1", server_context: server_context)
      }.to raise_error(DebugMcp::SessionError, /No active session/)
    end

    it "handles timeout error" do
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_raise(
        DebugMcp::TimeoutError, "Timeout after 15s"
      )

      response = described_class.call(code: "sleep(100)", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Timeout")
    end

    it "restores stdout on error" do
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_raise(
        DebugMcp::ConnectionError, "lost"
      )

      response = described_class.call(code: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error:")
    end

    it "suspends and restores catch breakpoints" do
      bp_info = "#1  BP - Catch  \"NoMethodError\"\n#2  BP - Line  file.rb:10"
      allow(client).to receive(:send_command).with("info break").and_return(bp_info)
      allow(client).to receive(:send_command).with("delete 1").and_return("")
      allow(client).to receive(:send_command).with("catch NoMethodError").and_return("")
      allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

      described_class.call(code: "1 + 1", server_context: server_context)

      expect(client).to have_received(:send_command).with("delete 1")
      expect(client).to have_received(:send_command).with("catch NoMethodError")
    end

    it "uses Base64 encoding for multi-line code" do
      allow(client).to receive(:send_command).with(/Base64/).and_return("=> 3")
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

      described_class.call(code: "a = 1\na + 2", server_context: server_context)
      expect(client).to have_received(:send_command).with(/Base64/)
    end

    it "uses Base64 encoding for non-ASCII code" do
      allow(client).to receive(:send_command).with(/Base64/).and_return('=> "hello"')
      allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

      described_class.call(code: 'puts "日本語"', server_context: server_context)
      expect(client).to have_received(:send_command).with(/Base64/)
    end

    context "event source tagging (ADR-0003)" do
      it "sets Thread.current[:_debug_mcp_event_source] before single-line eval" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

        described_class.call(code: "User.count", server_context: server_context)
        expect(client).to have_received(:send_command).with(/Thread\.current\[:_debug_mcp_event_source\]=:debug_eval/)
      end

      it "restores the previous tag via pop on single-line eval" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

        described_class.call(code: "1 + 1", server_context: server_context)
        # SourceTagging.wrap uses a Thread-local stack so nested wraps are safe
        expect(client).to have_received(:send_command).with(/Thread\.current\[:_debug_mcp_event_source_stack\]\.pop/)
      end

      it "sets and restores the tag in Base64-encoded multi-line eval" do
        allow(client).to receive(:send_command).with(/Base64/).and_return("=> 3")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return('=> nil')
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

        described_class.call(code: "a = 1\na + 2", server_context: server_context)
        expect(client).to have_received(:send_command).with(
          a_string_matching(/Thread\.current\[:_debug_mcp_event_source\]=:debug_eval/)
            .and(a_string_matching(/Thread\.current\[:_debug_mcp_event_source_stack\]\.pop/)),
        )
      end
    end

    context "trap context annotation" do
      it "appends trap context note with stdout capture hint" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).and_return("")
        allow(client_in_trap).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin/).and_return("=> 42")
        allow(client_in_trap).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")

        response = described_class.call(
          code: "1 + 1",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("[trap context")
        expect(text).to include("stdout capture")
        expect(text).to include("expression return values")
      end

      it "does not append trap context note when not in trap context" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("trap context")
      end
    end

    context "frame info display" do
      it "prepends frame info when not at frame 0" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return(
          "#2  Object#method_a at /app/models/user.rb:25"
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to start_with("Frame #2:")
        expect(text).to include("Object#method_a")
      end

      it "does not prepend frame info at frame 0" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return(
          "#0  UsersController#show at app/controllers/users_controller.rb:10"
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("Frame #0")
      end

      it "ignores frame errors gracefully" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_raise(
          DebugMcp::TimeoutError, "timeout"
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to include("42")
        expect(text).not_to include("Frame")
      end
    end

    context "safety warnings" do
      it "prepends warning for dangerous code" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> :ok")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")

        response = described_class.call(code: 'File.write("/tmp/x", "data")', server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("File system operations:")
        expect(text).to include("The code was executed. Result follows:")
        expect(text).to include(":ok")
      end

      it "does not prepend warning for safe code" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")

        response = described_class.call(code: "user.name", server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("WARNING:")
        expect(text).not_to include("Result follows:")
      end

      it "prepends warning in trap context" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).and_return("")
        allow(client_in_trap).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin/).and_return('=> :ok')
        allow(client_in_trap).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")

        response = described_class.call(
          code: 'system("ls")',
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("System command execution:")
        expect(text).to include("[trap context")
      end

      it "includes execution result even when warning is present" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> true")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")

        response = described_class.call(code: "User.destroy_all", server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("Destructive data operations:")
        expect(text).to include("true")
      end

      it "detects multiple dangerous categories" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> nil")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")

        response = described_class.call(
          code: 'system("curl http://example.com"); File.write("/tmp/x", result)',
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("File system operations:")
        expect(text).to include("System command execution:")
      end
    end

    context "acknowledge_mutations" do
      before do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> true")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")
      end

      it "suppresses mutation warnings when acknowledge_mutations is true" do
        allow(manager).to receive(:acknowledged_warnings).and_return(Set[:mutation_operations])

        response = described_class.call(
          code: "user.save!", acknowledge_mutations: true, server_context: server_context,
        )
        text = response_text(response)

        expect(manager).to have_received(:acknowledge_warning).with(nil, :mutation_operations)
        expect(text).not_to include("WARNING:")
        expect(text).not_to include("Data mutation")
      end

      it "still shows non-mutation warnings even when mutations are acknowledged" do
        allow(manager).to receive(:acknowledged_warnings).and_return(Set[:mutation_operations])

        response = described_class.call(
          code: 'system("ls"); user.save!', acknowledge_mutations: true, server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("System command execution")
        expect(text).not_to include("Data mutation")
      end

      it "shows mutation warnings when not acknowledged" do
        response = described_class.call(
          code: "user.save!", server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Note:")
        expect(text).to include("Data mutation")
      end
    end

    context "ThreadError detection" do
      it "shows trap context guidance when ThreadError occurs in evaluation" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> nil")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return(
          '=> "ThreadError: can\'t be called from trap context"'
        )
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

        response = described_class.call(code: "User.first", server_context: server_context)
        text = response_text(response)

        expect(text).to include("ThreadError")
        expect(text).to include("signal trap context")
        expect(text).to include("set_breakpoint")
        expect(text).to include("trigger_request")
      end

      it "does not show trap context guidance for non-ThreadError errors" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> nil")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return(
          '=> "NameError: undefined local variable \'x\'"'
        )
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return('=> ""')

        response = described_class.call(code: "x", server_context: server_context)
        text = response_text(response)

        expect(text).to include("NameError")
        expect(text).not_to include("trap context")
      end
    end

    context "trap context error detection" do
      let(:client_in_trap) { build_mock_client(trap_context: true) }
      let(:manager_in_trap) { build_mock_manager(client: client_in_trap) }

      before do
        allow(client_in_trap).to receive(:send_command).and_return("")
      end

      it "detects error via $__debug_mcp_err in trap context" do
        allow(client_in_trap).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin/).and_return("=> nil")
        allow(client_in_trap).to receive(:send_command).with("p $__debug_mcp_err").and_return(
          '=> "NameError: undefined local variable \'x\'"'
        )

        response = described_class.call(
          code: "x",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("Error:")
        expect(text).to include("NameError")
      end

      it "returns normal value when no error in trap context" do
        allow(client_in_trap).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin/).and_return("=> 42")
        allow(client_in_trap).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")

        response = described_class.call(
          code: "1 + 1",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("42")
        expect(text).not_to include("Error:")
      end

      it "shows ThreadError guidance in trap context" do
        allow(client_in_trap).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin/).and_return("=> nil")
        allow(client_in_trap).to receive(:send_command).with("p $__debug_mcp_err").and_return(
          '=> "ThreadError: can\'t be called from trap context"'
        )

        response = described_class.call(
          code: "User.first",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("ThreadError")
        expect(text).to include("signal trap context")
        expect(text).to include("set_breakpoint")
        expect(text).to include("trigger_request")
      end

      it "handles multi-line code in trap context with error detection" do
        allow(client_in_trap).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin; eval/).and_return("=> 3")
        allow(client_in_trap).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")

        response = described_class.call(
          code: "a = 1\na + 2",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("3")
        expect(text).not_to include("Error:")
      end
    end

    context "$__debug_mcp_cap nil safety" do
      it "handles nil $__debug_mcp_cap gracefully" do
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = STDOUT; p $__debug_mcp_cap&.string").and_return("=> nil")
        allow(client).to receive(:send_command).with("frame", timeout: 3).and_return("#0 main at file.rb:1")

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to include("42")
        expect(text).not_to include("IO")
        expect(text).not_to include("STDOUT")
      end
    end

    context "pending HTTP notification" do
      it "appends note when HTTP response is ready" do
        holder = { response: { status: "200 OK" }, error: nil, done: true }
        allow(client).to receive(:pending_http).and_return(
          { holder: holder, method: "GET", url: "http://localhost:3000/users" },
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to include("HTTP response received (200 OK)")
        expect(text).to include("continue_execution")
      end

      it "does not append note when no pending HTTP" do
        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("HTTP response")
      end

      it "appends note in trap context path" do
        allow(client).to receive(:trap_context).and_return(true)
        allow(client).to receive(:send_command).with(/\$__debug_mcp_err=nil; p\(begin/).and_return('=> 2')
        allow(client).to receive(:send_command).with("p $__debug_mcp_err").and_return("=> nil")
        holder = { response: { status: "200 OK" }, error: nil, done: true }
        allow(client).to receive(:pending_http).and_return(
          { holder: holder, method: "POST", url: "http://localhost:3000/users" },
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to include("HTTP response received (200 OK)")
      end
    end
  end
end
