# frozen_string_literal: true

RSpec.describe DebugMcp::Tools::InspectObject do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  # Command matchers: inspect_object now wraps user expressions with
  # SourceTagging (ADR-0003) so events fired during inspection are tagged
  # :debug_eval. Tests match against substrings instead of literal commands.
  def pp_value_matching(expr)
    a_string_matching(/\App\(.*\(#{Regexp.escape(expr)}\).*\)\z/m)
  end

  def meta_matching(expr)
    a_string_matching(/\Ap\(.*instance_variables.*class_variables.*\)\z/m)
      .and(a_string_matching(/#{Regexp.escape(expr)}/))
  end

  def cvar_matching(expr)
    a_string_matching(/\App\(.*class_variable_get.*\)\z/m)
      .and(a_string_matching(/#{Regexp.escape(expr)}/))
  end

  describe ".call" do
    it "returns value, class, and instance variables" do
      allow(client).to receive(:send_command).with(pp_value_matching("user")).and_return('#<User id: 1, name: "Alice">')
      allow(client).to receive(:send_command).with(meta_matching("user")).and_return('=> ["User", [:@id, :@name], nil]')

      response = described_class.call(expression: "user", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("User")
      expect(text).to include("Class: User")
      expect(text).to include("Instance variables: [:@id, :@name]")
      expect(text).not_to include("Class variables:")
    end

    it "handles timeout on meta query gracefully" do
      allow(client).to receive(:send_command).with(pp_value_matching("x")).and_return("42")
      allow(client).to receive(:send_command).with(meta_matching("x")).and_raise(DebugMcp::TimeoutError, "timeout")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("42")
      expect(text).to include("Class: (timed out)")
      expect(text).to include("Instance variables: (timed out)")
    end

    it "handles unparseable meta output gracefully" do
      allow(client).to receive(:send_command).with(pp_value_matching("x")).and_return("42")
      allow(client).to receive(:send_command).with(meta_matching("x")).and_return("=> something unexpected")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("Class: something unexpected")
    end

    context "class variables" do
      it "displays class variable values when inspecting a Class object" do
        allow(client).to receive(:send_command).with(pp_value_matching("Order")).and_return("Order")
        allow(client).to receive(:send_command).with(meta_matching("Order")).and_return('=> ["Class", [:@table_name], [:@@count, :@@default_status]]')
        allow(client).to receive(:send_command).with(cvar_matching("Order")).and_return('{:@@count=>42, :@@default_status=>:pending}')

        response = described_class.call(expression: "Order", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class: Class")
        expect(text).to include("Instance variables: [:@table_name]")
        expect(text).to include("Class variables:\n{:@@count=>42, :@@default_status=>:pending}")
      end

      it "falls back to names only when class variable value query times out" do
        allow(client).to receive(:send_command).with(pp_value_matching("Order")).and_return("Order")
        allow(client).to receive(:send_command).with(meta_matching("Order")).and_return('=> ["Class", [:@table_name], [:@@count]]')
        allow(client).to receive(:send_command).with(cvar_matching("Order")).and_raise(DebugMcp::TimeoutError, "timeout")

        response = described_class.call(expression: "Order", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class variables: [:@@count]")
      end

      it "does not display class variables section for regular instances" do
        allow(client).to receive(:send_command).with(pp_value_matching("obj")).and_return('#<Object:0x00007f>')
        allow(client).to receive(:send_command).with(meta_matching("obj")).and_return('=> ["Object", [:@x], nil]')

        response = described_class.call(expression: "obj", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class: Object")
        expect(text).to include("Instance variables: [:@x]")
        expect(text).not_to include("Class variables:")
      end

      it "displays empty class variables for a Class with no class variables" do
        allow(client).to receive(:send_command).with(pp_value_matching("MyClass")).and_return("MyClass")
        allow(client).to receive(:send_command).with(meta_matching("MyClass")).and_return('=> ["Class", [], []]')

        response = described_class.call(expression: "MyClass", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class: Class")
        expect(text).to include("Class variables: []")
      end
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(DebugMcp::SessionError, "No session")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end

    context "trap context annotation" do
      it "appends [trap context] when in trap context" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).with(pp_value_matching("user")).and_return("42")
        allow(client_in_trap).to receive(:send_command).with(meta_matching("user")).and_return('=> ["Integer", [], nil]')

        response = described_class.call(
          expression: "user",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("[trap context]")
      end

      it "does not append [trap context] when not in trap context" do
        allow(client).to receive(:send_command).with(pp_value_matching("x")).and_return("42")
        allow(client).to receive(:send_command).with(meta_matching("x")).and_return('=> ["Integer", [], nil]')

        response = described_class.call(expression: "x", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("[trap context]")
      end
    end

    context "pending HTTP notification" do
      it "includes note when HTTP response is ready" do
        holder = { response: { status: "200 OK" }, error: nil, done: true }
        allow(client).to receive(:pending_http).and_return(
          { holder: holder, method: "GET", url: "http://localhost:3000/" },
        )
        allow(client).to receive(:send_command).with(pp_value_matching("x")).and_return("42")
        allow(client).to receive(:send_command).with(meta_matching("x")).and_return('=> ["Integer", [], nil]')

        response = described_class.call(expression: "x", server_context: server_context)
        text = response_text(response)
        expect(text).to include("HTTP response received (200 OK)")
      end

      it "includes error note when HTTP failed" do
        error = StandardError.new("connection refused")
        holder = { response: nil, error: error, done: true }
        allow(client).to receive(:pending_http).and_return(
          { holder: holder, method: "POST", url: "http://localhost:3000/users" },
        )
        allow(client).to receive(:send_command).with(pp_value_matching("x")).and_return("42")
        allow(client).to receive(:send_command).with(meta_matching("x")).and_return('=> ["Integer", [], nil]')

        response = described_class.call(expression: "x", server_context: server_context)
        text = response_text(response)
        expect(text).to include("HTTP request (POST http://localhost:3000/users) failed")
      end
    end

    context "event source tagging (ADR-0003)" do
      it "wraps the value query with SourceTagging" do
        allow(client).to receive(:send_command).with(pp_value_matching("user")).and_return("...")
        allow(client).to receive(:send_command).with(meta_matching("user")).and_return('=> ["User", [], nil]')

        described_class.call(expression: "user", server_context: server_context)
        expect(client).to have_received(:send_command).with(a_string_matching(/Thread\.current\[:_debug_mcp_event_source\]=:debug_eval/)).at_least(:twice)
      end
    end
  end
end
