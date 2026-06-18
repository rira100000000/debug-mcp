# frozen_string_literal: true

require "set"
require "debug_mcp"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

# Helper to build a mock DebugClient
def build_mock_client(connected: true, pid: "12345", paused: true, trap_context: false, remote: false, port: nil)
  client = instance_double(DebugMcp::DebugClient,
    connected?: connected,
    pid: pid,
    paused: paused,
    trap_context: trap_context,
    remote: remote,
    port: port,
    wait_thread: nil,
    stderr_file: nil,
    stdout_file: nil,
    script_file: nil,
    script_args: nil,
    pending_http: nil,
    listen_ports: [],
    escape_target: nil,
    suspended_catch_bps: [],
  )
  allow(client).to receive(:send_command).and_return("")
  allow(client).to receive(:send_command_no_wait)
  allow(client).to receive(:send_continue).and_return("")
  allow(client).to receive(:check_current_exception).and_return(nil)
  allow(client).to receive(:cleanup_one_shot_breakpoints).and_return(nil)
  allow(client).to receive(:process_finished?).and_return(false)
  allow(client).to receive(:disconnect)
  allow(client).to receive(:read_stdout_output).and_return(nil)
  allow(client).to receive(:read_stderr_output).and_return(nil)
  allow(client).to receive(:find_raised_exception).and_return(nil)
  allow(client).to receive(:in_trap_context?).and_return(trap_context)
  allow(client).to receive(:escape_trap_context!).and_return(nil)
  allow(client).to receive(:ensure_paused).and_return("")
  allow(client).to receive(:repause).and_return("")
  allow(client).to receive(:auto_repause!).and_return(false)
  allow(client).to receive(:interrupt_and_wait).and_return("")
  allow(client).to receive(:continue_and_wait).and_return({ type: :timeout, output: "" })
  allow(client).to receive(:wait_for_breakpoint).and_return({ type: :timeout, output: "" })
  allow(client).to receive(:wake_io_blocked_process).and_return(Thread.new {})
  allow(client).to receive(:pending_http=)
  allow(client).to receive(:listen_ports=)
  allow(client).to receive(:escape_target=)
  allow(client).to receive(:suspended_catch_bps=)
  client
end

# Helper to build a mock SessionManager
def build_mock_manager(client: nil)
  client ||= build_mock_client
  manager = instance_double(DebugMcp::SessionManager)
  allow(manager).to receive(:client).and_return(client)
  allow(manager).to receive(:record_breakpoint)
  allow(manager).to receive(:clear_breakpoint_specs)
  allow(manager).to receive(:remove_breakpoint_specs_matching)
  allow(manager).to receive(:restore_breakpoints).and_return([])
  allow(manager).to receive(:cleanup_dead_sessions).and_return([])
  allow(manager).to receive(:active_sessions).with(any_args).and_return([])
  allow(manager).to receive(:disconnect)
  allow(manager).to receive(:timeout).and_return(1800)
  allow(manager).to receive(:acknowledge_warning)
  allow(manager).to receive(:acknowledged_warnings).and_return(Set.new)
  allow(manager).to receive(:connect).and_return({
    success: true, pid: "12345", output: "stopped at line 1", session_id: "session_12345",
  })
  manager
end

# Helper to extract text from MCP::Tool::Response
def response_text(response)
  response.content.first[:text]
end

# Build a debug-gem `=> "<base64>"` response line for a value that the target
# returned as `[obj.to_json].pack("m0")` (see RailsHelper.json_command). This is
# how Rails observability tools transport JSON, since the debug socket does not
# forward the debuggee's stdout.
def debug_eval_json(obj)
  require "base64"
  require "json"
  b64 = [obj.to_json].pack("m0") # base64 alphabet only — no inspect escaping needed
  "=> \"#{b64}\""
end
