# debug-mcp

[日本語版 (Japanese)](README.ja.md)

MCP (Model Context Protocol) server that connects LLM agents to Ruby's [debug gem](https://github.com/ruby/debug), giving them access to the runtime context of paused Ruby processes.

LLM agents can connect to a paused Ruby process, inspect variables, evaluate code, set breakpoints, and control execution — all through MCP tool calls.

## What it does

Existing Ruby/Rails MCP servers only provide static analysis or application-level APIs. debug-mcp goes further: it connects to **running Ruby processes** via the debug gem and exposes their runtime state to LLM agents.

```
Agent → connect(host: "localhost", port: 12345)
Agent → get_context()
  → local variables, instance variables, call stack
Agent → evaluate_code(code: "user.valid?")
  → false
Agent → evaluate_code(code: "user.errors.full_messages")
  → ["Email can't be blank"]
Agent → continue_execution()
```

## Installation

```ruby
gem "debug-mcp"
```

Or install directly:

```
gem install debug-mcp
```

Requires Ruby >= 3.2.0.

> **Migrating from `girb-mcp`?** This gem was previously published as `girb-mcp`
> on RubyGems (last version: 0.1.1). It was renamed to `debug-mcp` starting from
> 0.1.2 to better reflect its purpose. Replace `gem "girb-mcp"` with
> `gem "debug-mcp"` and update your MCP client config (`girb-mcp` → `debug-mcp`,
> `girb-rails` → `debug-rails`). See [CHANGELOG.md](CHANGELOG.md) for details.

## Quick Start

### 1. Start a Ruby process with the debugger

```bash
# Script
rdbg --open --port=12345 my_script.rb

# Or with environment variables
RUBY_DEBUG_OPEN=true RUBY_DEBUG_PORT=12345 ruby my_script.rb

# Or add `debugger` / `binding.break` in your code and run with rdbg
rdbg --open my_script.rb
```

### 2. Configure your MCP client

debug-mcp works with any MCP-compatible client. Add it to your client's MCP server configuration:

#### Claude Code

Add to `~/.claude/settings.json` (or project `.claude/settings.json`):

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "debug-mcp",
      "args": []
    }
  }
}
```

If using Bundler:

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "bundle",
      "args": ["exec", "debug-mcp"]
    }
  }
}
```

#### Gemini CLI

Add to `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "debug-mcp",
      "args": []
    }
  }
}
```

If using Bundler:

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "bundle",
      "args": ["exec", "debug-mcp"]
    }
  }
}
```

### 3. Start debugging

Ask your agent to connect and debug:

> "Connect to the debug session on port 12345 and show me the current state"

> "Set a breakpoint at app/models/user.rb line 42 and send a GET request to /users/1"

## Usage

```
Usage: debug-mcp [options]
    -t, --transport TRANSPORT        Transport type: stdio (default) or http
    -p, --port PORT                  HTTP port (default: 6029, only for http transport)
        --host HOST                  HTTP host (default: 127.0.0.1, only for http transport)
        --session-timeout SECONDS    Session timeout in seconds (default: 1800)
    -v, --version                    Show version
    -h, --help                       Show this help
```

### STDIO transport (default)

Standard transport for MCP clients. No additional configuration needed.

```bash
debug-mcp
```

### HTTP transport (Streamable HTTP)

For browser-based clients or other HTTP-compatible MCP clients.

```bash
debug-mcp --transport http --port 8080
```

The MCP endpoint will be available at `http://127.0.0.1:8080/mcp`.

### Session timeout

Debug sessions are automatically cleaned up after 30 minutes of inactivity. Adjust with:

```bash
debug-mcp --session-timeout 3600  # 1 hour
```

The session manager also detects and cleans up sessions whose target process has exited.

## Tools

### Discovery & Connection

| Tool | Description |
|------|-------------|
| `list_debug_sessions` | List available debug sessions (Unix sockets) |
| `connect` | Connect to a debug session via socket path or TCP |
| `list_paused_sessions` | List currently connected sessions |

### Investigation

| Tool | Description |
|------|-------------|
| `evaluate_code` | Execute Ruby code in the stopped binding |
| `inspect_object` | Get class, value, and instance variables of an object |
| `get_context` | Local variables, instance variables, call stack, breakpoints |
| `get_source` | Source code of a method or class |
| `read_file` | Read source files with optional line range |
| `list_files` | List files in a directory, with optional glob pattern |

### Execution Control

| Tool | Description |
|------|-------------|
| `set_breakpoint` | Set a breakpoint: line (file + line), method (`User#save`), or exception class |
| `remove_breakpoint` | Remove a breakpoint by file + line, method name, exception class, or number |
| `continue_execution` | Resume execution until next breakpoint or exit |
| `step` | Step into the next method call |
| `next` | Step over to the next line |
| `finish` | Run until the current method/block returns |
| `run_debug_command` | Execute any raw debugger command |
| `disconnect` | Disconnect from the session and terminate the process |

### Entry Points

| Tool | Description |
|------|-------------|
| `run_script` | Start a Ruby script under rdbg and connect to it |
| `trigger_request` | Send an HTTP request to a Rails app under debug |

### Rails Tools (auto-detected)

These tools are automatically registered when a Rails process is detected.

| Tool | Description |
|------|-------------|
| `rails_info` | Show app name, Rails/Ruby versions, environment, root path |
| `rails_routes` | Show routes (verb, path, controller#action), filterable by controller or path |
| `rails_model` | Show model structure: columns, associations, validations, enums, scopes |

## Rails event capture

When `trigger_request` is used against a Rails app, the response includes a structured `Rails Events` section that surfaces what happened inside the request:

- SQL queries (duration, bind values, query name, cached flag)
- Renders (templates, partials, collections)
- Cache operations (read/write/fetch_hit, hit/miss)
- Enqueued ActiveJob jobs
- Request lifecycle (controller#action, status, view/db runtime)

This is captured via an `ActiveSupport::Notifications` subscriber that debug-mcp injects into the Rails process at first use — no gem installation in your Rails app required.

### Example output

```
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")

  HTTP 200 OK
  {...response body...}

  --- Rails Events ---
  ## Request
  GET /users/1 → UsersController#show
  Status: 200 — total 35.4ms (view 12.5ms, db 4.2ms)

  ## SQL (1 query)
  1. (0.66ms) User Load SELECT "users".* FROM "users" WHERE "users"."id" = 1 LIMIT 1
```

### Filtering: separating app execution from debugger inspection

When you call `evaluate_code` or `inspect_object` at a breakpoint, any AR queries those make run on the request thread and would otherwise look like application SQL. debug-mcp tags them with `source: :debug_eval` so the default view stays clean.

- **Default**: `:debug_eval` events are hidden — what you see is the app's own work.
- **`include_debug_eval: true`** on `trigger_request`: include them, useful for seeing what the debugger touched.

### Tuning the output volume

`trigger_request` accepts an `event_limits` object to override per-category caps:

```
trigger_request(
  method: "GET", url: "...",
  event_limits: { sql: 100, render: null }  # null disables the limit
)
```

Defaults: `sql=30`, `render=20`, `cache=20`, `job=unlimited`, `logger=50`.

## Workflows

### Debug a Ruby script

```
Agent: run_script(file: "my_script.rb")
Agent: get_context()
Agent: evaluate_code(code: "result")
Agent: next()
Agent: evaluate_code(code: "result")
Agent: continue_execution()
```

### Method breakpoints

```
Agent: run_script(file: "my_script.rb", breakpoints: ["DataPipeline#validate"])
  → Script starts and pauses at DataPipeline#validate
Agent: evaluate_code(code: "records")
Agent: continue_execution()
```

### Catch and debug exceptions

```
Agent: run_script(file: "my_script.rb")
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → Execution pauses BEFORE the exception propagates
Agent: get_context()
Agent: evaluate_code(code: "$!.message")
```

### Restart after a crash

```
  → Program crashed with NoMethodError
Agent: run_script(file: "my_script.rb", restore_breakpoints: true)
  → Same breakpoints restored automatically
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → Catches the exception before it crashes
```

### Debug a Rails request

Start your Rails server with debug enabled using `debug-rails`:

```bash
debug-rails                # equivalent to RUBY_DEBUG_OPEN=true bin/rails server
debug-rails s -p 4000      # specify port
debug-rails --debug-port 3333  # use specific TCP debug port (useful in Docker)
```

Then ask the agent to debug:

```
Agent: connect()
Agent: set_breakpoint(file: "app/controllers/users_controller.rb", line: 15)
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")
Agent: get_context()
Agent: evaluate_code(code: "@user.attributes")
Agent: continue_execution()
```

### Debug a Dockerized Rails app

> **Security note:** The debug gem has no authentication. Anyone who can reach the debug port can execute arbitrary code inside the container. Always restrict access as shown below.

#### Option A: Localhost-only TCP (simple)

Expose the debug port bound to `127.0.0.1` so only local processes can connect:

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
      - "127.0.0.1:12345:12345"  # localhost only
    environment:
      - RUBY_DEBUG_OPEN=true
      - RUBY_DEBUG_HOST=0.0.0.0
      - RUBY_DEBUG_PORT=12345
```

```
Agent: connect(port: 12345)
```

The agent can read source files inside the container — no local copy of the source code is needed.

#### Option B: Unix socket volume mount (recommended)

Mount a shared directory for the debug socket. No port exposure needed:

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
    environment:
      - RUBY_DEBUG_OPEN=true
      - RUBY_DEBUG_SOCK_PATH=/debug/rdbg.sock
    volumes:
      - debug_sock:/debug

volumes:
  debug_sock:
```

```
Agent: connect(path: "/path/to/debug_sock/rdbg.sock")
```

### Connect to an existing breakpoint

```bash
# Terminal: your app hits a `debugger` statement
rdbg --open my_app.rb
```

```
Agent: list_debug_sessions()
Agent: connect(path: "/tmp/rdbg-1000/rdbg-12345")
Agent: get_context()
```

## How it works

```
┌────────────┐  STDIO or Streamable HTTP  ┌───────────┐    TCP/Unix Socket    ┌──────────────┐
│ MCP Client │ ◄────────────────────────► │ debug-mcp  │ ◄──────────────────► │ Ruby process │
│            │        (JSON-RPC)          │(MCP Server)│    debug gem proto   │  (rdbg)      │
└────────────┘                            └───────────┘                      └──────────────┘
```

1. debug-mcp runs as an MCP server communicating via STDIO (default) or Streamable HTTP
2. The debug gem (`rdbg --open`) exposes a socket on the target Ruby process
3. debug-mcp connects to that socket using the debug gem's wire protocol
4. MCP tool calls are translated to debugger commands and results are returned
5. Idle sessions are automatically cleaned up after a configurable timeout

## Security

debug-mcp is a debugging tool that intentionally provides deep runtime access. Here's what you should know:

**For development environments only.** debug-mcp is meant for attaching to your own local or development processes — not production. It grants deep runtime access (including code execution via `evaluate_code`) and is not designed to be safe against a hostile target.

**Structured tools minimize arbitrary code execution.** Most debugging tasks — viewing variables, reading source code, inspecting model structure — are handled by dedicated tools that don't run arbitrary code. `evaluate_code` is available for runtime inspection, and a built-in safety checker warns about dangerous operations. Note that this checker and the tool-selection guidance are advisory — they nudge the agent but do not block execution.

**Don't point it at untrusted data.** The agent reads runtime data from the target process (variable values, DB rows, HTTP responses) and can act on it via `evaluate_code`. Because the safeguards above are advisory, a prompt-injection payload in that data could steer the agent. Don't run debug-mcp against a process handling input where injection could be introduced.

**The debug gem has no authentication.** Anyone who can reach the debug socket can execute arbitrary code in the target process. Always bind to localhost (`127.0.0.1`) or use Unix sockets. See the [Docker section](#debug-a-dockerized-rails-app) for configuration examples.

## Related projects

- [girb](https://github.com/rira100000000/girb) — AI-powered IRB assistant for humans, sharing the same philosophy.

## Development

```bash
git clone https://github.com/rira100000000/debug-mcp.git
cd debug-mcp
bundle install
```

## License

MIT
