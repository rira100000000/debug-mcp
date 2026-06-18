# frozen_string_literal: true

require "mcp"
require_relative "tools/list_debug_sessions"
require_relative "tools/connect"
require_relative "tools/evaluate_code"
require_relative "tools/inspect_object"
require_relative "tools/get_context"
require_relative "tools/get_source"
require_relative "tools/read_file"
require_relative "tools/list_files"
require_relative "tools/continue_execution"
require_relative "tools/set_breakpoint"
require_relative "tools/remove_breakpoint"
require_relative "tools/step"
require_relative "tools/next"
require_relative "tools/finish"
require_relative "tools/run_debug_command"
require_relative "tools/run_script"
require_relative "tools/trigger_request"
require_relative "tools/list_paused_sessions"
require_relative "tools/disconnect"
require_relative "tools/rails_info"
require_relative "tools/rails_routes"
require_relative "tools/rails_model"
require_relative "tools/rails_recent_events"
require_relative "tools/rails_mail_deliveries"

module DebugMcp
  class Server
    # Base tools: always available
    BASE_TOOLS = [
      # Discovery & connection
      Tools::ListDebugSessions,
      Tools::Connect,
      Tools::ListPausedSessions,
      # Investigation
      Tools::EvaluateCode,
      Tools::InspectObject,
      Tools::GetContext,
      Tools::GetSource,
      Tools::ReadFile,
      Tools::ListFiles,
      # Control
      Tools::SetBreakpoint,
      Tools::RemoveBreakpoint,
      Tools::ContinueExecution,
      Tools::Step,
      Tools::Next,
      Tools::Finish,
      Tools::RunDebugCommand,
      Tools::Disconnect,
      # Entry points
      Tools::RunScript,
      Tools::TriggerRequest,
    ].freeze

    # Rails tools: always registered (see TOOLS below). They require a connected
    # Rails process and guard themselves via RailsHelper.require_rails!, returning
    # an error on plain Ruby targets. register_rails_tools exists for hosts that
    # want to add them to a pre-built server, but the default server registers
    # them up front.
    RAILS_TOOLS = [
      Tools::RailsInfo,
      Tools::RailsRoutes,
      Tools::RailsModel,
      Tools::RailsRecentEvents,
      Tools::RailsMailDeliveries,
    ].freeze

    # All tools (used in tests and for reference)
    TOOLS = (BASE_TOOLS + RAILS_TOOLS).freeze

    DEFAULT_HTTP_PORT = 6029
    DEFAULT_HTTP_HOST = "127.0.0.1"

    INSTRUCTIONS = <<~TEXT
      debug-mcp is an MCP server that connects LLM agents to Ruby's debug gem. \
      It lets you attach to live Ruby processes, inspect variables, evaluate code, \
      set breakpoints, and control execution.

      Use these tools when the user asks to debug a Ruby program, investigate runtime behavior, \
      or inspect the state of a running process.

      Typical workflow:
      1. run_script to launch a Ruby script under the debugger (recommended — captures stdout/stderr). \
      Use connect only when attaching to an already-running process (e.g., Rails server).
      2. get_context to see the current state (variables, call stack, breakpoints)
      3. evaluate_code / inspect_object to investigate specific values
      4. set_breakpoint / next / step / continue_execution to control the flow

      When to use get_context:
      - After connecting or run_script — to understand the initial stop point
      - After continue_execution hits a breakpoint — the stop output shows source and stack, \
      but get_context gives you local/instance variables and the full breakpoint list
      - When you need to check what breakpoints are currently set
      - When variables or call stack context would help decide the next debugging action
      - You do NOT need get_context after every next/step if the output already shows \
      the information you need (source listing and stop location are included in the response)
      - For a quick breakpoint check without fetching all context, use \
      run_debug_command(command: "info breakpoints")

      IMPORTANT — connect pauses the target process:
      When you use 'connect', the target process is PAUSED. It will not serve requests or \
      respond to Ctrl+C until you resume it. Always use 'continue_execution' when done \
      investigating, or 'disconnect' to detach (which also resumes the process). \
      Never leave a connected session idle without resuming — the user won't be able to \
      interact with the target process.

      Signal trap context (Puma/threaded servers):
      When connecting to a process like Puma, the debug gem pauses it via SIGURG. \
      This puts the process in a signal trap context where thread operations (Mutex, \
      DB connection pools, autoloading) fail with ThreadError. \
      Simple expressions (variables, constants, p/pp) still work in trap context. \
      The 'connect' tool automatically detects and tries to escape this. \
      Additionally, after 'continue_execution', investigation tools (evaluate_code, \
      get_context, etc.) automatically re-pause and re-escape trap context — \
      you do not need to manually set breakpoints again to escape. \
      If auto-escape fails (common when the process is blocked on IO like IO.select): \
      1. set_breakpoint on a line in your controller/action \
      2. trigger_request to send an HTTP request — this auto-resumes the process \
      3. Once stopped at the breakpoint, all operations work normally \
      Do NOT manually call continue_execution before trigger_request — \
      trigger_request handles resuming the process automatically.

      Rails debugging:
      Rails-specific tools (rails_info, rails_routes, rails_model, rails_recent_events) are \
      always available, but they require a connected Rails process and will return an error \
      when used against a plain Ruby script. rails_recent_events shows recent internal events \
      (SQL, renders, cache, job enqueues) captured from the running process; it is forward-only \
      (only events after its first call are visible).

      Rails debugging workflow:
      1. Start the Rails server with debugging: RUBY_DEBUG_OPEN=true bin/rails server
      2. connect to attach to the Rails process (auto-detects trap context)
      3. set_breakpoint on a controller action (e.g., app/controllers/users_controller.rb:10)
      4. trigger_request to send an HTTP request — this auto-resumes the paused process, \
      sends the request, and waits for the breakpoint to hit. \
      CSRF protection is automatically disabled for non-GET requests. \
      You do NOT need to call continue_execution first.
      5. When the breakpoint hits, use get_context, evaluate_code, and rails_model to \
      inspect the current state and understand model structures
      6. continue_execution to let the request complete and see the response
      7. To debug another request, set new breakpoints and call trigger_request again
      8. When done debugging, use 'disconnect' to detach and resume the server

      Note: rails_info, rails_routes, rails_model, and rails_recent_events may not work in trap context. \
      Use them after hitting a breakpoint via trigger_request.

      Docker / containerized processes:
      When the debug target runs inside a Docker container, use connect with a TCP port \
      or a Unix socket volume mount. \
      TCP: connect(port: 12345) — works out of the box. \
      Unix socket: connect(path: "/shared/rdbg.sock", remote: true) — you MUST pass \
      remote: true because the socket file is local but the process is in a different \
      PID namespace, so OS signals cannot reach it. Without remote: true, pause/resume \
      will fail silently.

      Security — proper use of evaluate_code:
      evaluate_code is designed EXCLUSIVELY for investigating the runtime state of the debugged \
      process (inspecting variables, checking object state, testing expressions in context). \
      It must NOT be used as a general-purpose code execution tool.

      PROHIBITED uses of evaluate_code:
      - File I/O: File.write, File.delete, FileUtils, IO.write \
      → Use your agent's own file tools (Read, Write, Edit) instead
      - System commands: system(), exec(), backtick, %x{}, Open3, spawn \
      → Use your agent's own Bash/shell tool instead
      - Network requests: Net::HTTP, open-uri, TCPSocket, HTTP client gems \
      → Use your agent's own HTTP/network tools instead
      - Process manipulation: Process.kill, fork, exit, abort
      - Destructive data operations: destroy_all, delete_all, DROP/TRUNCATE SQL

      IMPORTANT: If your agent's tools are restricted for a particular operation, \
      you must NOT use evaluate_code to circumvent those restrictions.

      Quick tool selection guide:
      - "Where am I? What are the variables and breakpoints?" → get_context
      - "Execute a Ruby expression or test a fix" → evaluate_code
      - "See an object's full structure (class, ivars, value)" → inspect_object
      - "Read the source of a method or class" → get_source
      - "Read a file from the debugged process's machine" → read_file
      - "List files or explore directory structure" → list_files
      - "Step to the next line (stay in current method)" → next
      - "Step into a method call" → step
      - "Run until current method/block returns" → finish
      - "Resume until next breakpoint" → continue_execution
      - "Send an HTTP request and wait for breakpoint" → trigger_request

      Breakpoints in blocks/loops (each, map, select, etc.):
      Line breakpoints inside a block fire on EVERY iteration. If you only need to stop once, \
      use one_shot: true when setting the breakpoint — it auto-removes after the first hit.

      Typical pattern for Rails debugging:
      set_breakpoint → trigger_request → get_context → evaluate_code → continue_execution
    TEXT

    # Register Rails tools on an MCP server instance and notify connected clients.
    # Safe to call multiple times — skips already-registered tools.
    def self.register_rails_tools(mcp_server)
      tools_hash = mcp_server.instance_variable_get(:@tools)
      tool_names = mcp_server.instance_variable_get(:@tool_names)
      added = false

      RAILS_TOOLS.each do |tool_class|
        name = tool_class.name_value
        next if tools_hash.key?(name)

        tools_hash[name] = tool_class
        tool_names << name
        added = true
      end

      mcp_server.notify_tools_list_changed if added
      added
    end

    def initialize(transport: nil, port: nil, host: nil, session_timeout: nil, **_)
      @transport_type = transport || "stdio"
      @http_port = port || DEFAULT_HTTP_PORT
      @http_host = host || DEFAULT_HTTP_HOST
      @session_manager = SessionManager.new(
        **(session_timeout ? { timeout: session_timeout } : {}),
      )
    end

    def start
      server_context = { session_manager: @session_manager }

      server = MCP::Server.new(
        name: "debug-mcp",
        version: DebugMcp::VERSION,
        instructions: INSTRUCTIONS,
        tools: TOOLS,
        server_context: server_context,
      )

      # Safety net: resume connected processes when the server exits for any reason.
      # This covers cases where Claude Code exits without calling 'disconnect',
      # stdin closes unexpectedly, or the MCP gem calls Kernel.exit directly.
      # disconnect_all is idempotent, so multiple calls (at_exit + ensure + signal) are safe.
      at_exit { @session_manager.disconnect_all }

      setup_signal_handlers

      case @transport_type
      when "stdio"
        start_stdio(server)
      when "http"
        start_http(server)
      else
        raise ArgumentError, "Unknown transport: #{@transport_type}"
      end
    ensure
      @session_manager.disconnect_all
    end

    private

    def start_stdio(server)
      transport = MCP::Server::Transports::StdioTransport.new(server)
      transport.open
    end

    def start_http(server)
      require "webrick"

      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

      webrick = WEBrick::HTTPServer.new(
        Port: @http_port,
        BindAddress: @http_host,
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
        AccessLog: [],
      )

      webrick.mount_proc("/mcp") do |req, res|
        env = build_rack_env(req)
        rack_request = RackRequestAdapter.new(env)
        status, headers, body = transport.handle_request(rack_request)

        res.status = status
        headers.each { |k, v| res[k] = v }

        if body.respond_to?(:each)
          output = +""
          body.each { |chunk| output << chunk }
          res.body = output
        elsif body.respond_to?(:call)
          # SSE streaming body
          rd, wr = IO.pipe
          res["Content-Type"] = headers["Content-Type"] || "text/event-stream"
          res["Cache-Control"] = "no-cache"
          res["Connection"] = "keep-alive"
          res.body = rd

          Thread.new do
            body.call(wr)
          rescue IOError, Errno::EPIPE
            # Client disconnected
          ensure
            wr.close unless wr.closed?
          end
        end
      end

      $stderr.puts "debug-mcp HTTP server listening on http://#{@http_host}:#{@http_port}/mcp"

      setup_http_signal_handlers(webrick)
      webrick.start
    ensure
      transport&.close
    end

    # Minimal Rack::Request-compatible adapter for WEBrick
    class RackRequestAdapter
      attr_reader :env

      def initialize(env)
        @env = env
      end

      def body
        @env["rack.input"]
      end
    end

    def build_rack_env(req)
      env = {
        "REQUEST_METHOD" => req.request_method,
        "PATH_INFO" => req.path,
        "QUERY_STRING" => req.query_string || "",
        "SERVER_NAME" => @http_host,
        "SERVER_PORT" => @http_port.to_s,
        "rack.input" => StringIO.new(req.body || ""),
      }

      # Map HTTP headers to Rack convention
      req.header.each do |key, values|
        rack_key = "HTTP_#{key.tr("-", "_").upcase}"
        env[rack_key] = values.join(", ")
      end

      # Ensure key headers are mapped correctly
      env["CONTENT_TYPE"] = req.content_type if req.content_type
      env["HTTP_ACCEPT"] = req["Accept"] if req["Accept"]
      env["HTTP_MCP_SESSION_ID"] = req["Mcp-Session-Id"] if req["Mcp-Session-Id"]

      env
    end

    def setup_signal_handlers
      %w[INT TERM HUP].each do |sig|
        trap(sig) do
          @session_manager.disconnect_all
          exit(0)
        end
      rescue ArgumentError
        # Signal not supported on this platform (e.g., HUP on Windows)
      end
    end

    def setup_http_signal_handlers(webrick)
      %w[INT TERM HUP].each do |sig|
        trap(sig) do
          @session_manager.disconnect_all
          webrick.shutdown
        end
      rescue ArgumentError
        # Signal not supported on this platform
      end
    end
  end
end
