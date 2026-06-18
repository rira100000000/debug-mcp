# Changelog

## 0.3.0 — 2026-06-18

### Features

- **`rails_recent_events` tool** — Read recent Rails internal events (SQL, renders,
  cache, job enqueues, request lifecycle) from the running process without
  `trigger_request`. Forward-only (the first call installs the subscriber) and
  paused-only; every response carries an observability header (`installed_at`,
  `forward_only`, `events_before_install_are_unavailable`, buffer size + dropped
  count, `seq` range) so an empty result is never mistaken for "nothing happened".
  Clock-independent `after_seq` cursor paging.

- **`rails_mail_deliveries` tool** — Structure `ActionMailer::Base.deliveries`
  (from/to/cc/bcc/subject/body preview/attachment names). `observable` is true only
  when `delivery_method` is `:test`; otherwise the response states that an empty list
  is not proof no mail was sent. Bodies are truncated to a preview inside the target
  process (transport-safe, PII-safe by default); attachment content is never returned.

- **`rails_info` Observability section** — `rails_info` now reports `delivery_method`,
  ActiveJob `queue_adapter`, cache store, and PID, so an agent can tell up front
  whether mail/jobs are observable in this process.

### Bug Fixes

- **NotificationsSubscriber lifecycle (machine-verified)** — The injected buffer
  module now separates definition from activation: `.install` is always called and is
  idempotent, so a module left with zero subscriptions (e.g. an install attempt that
  raised in signal trap context, where `ActiveSupport::Notifications.subscribe` takes
  an internal mutex) recovers on the next injection instead of being permanently
  poisoned. `install` refuses early in trap context. The injected module is versioned
  so an older one in a long-running process is replaced. Reads use `Mutex#try_lock`
  with a lockless fallback so a fetch can't deadlock against a debugger-stopped thread.
  Per-event monotonic `seq` with clock-independent `fetch_last` / `fetch_after_seq`.
  SQL bodies and request paths are truncated at save time.

- **Notifications event capture over the debug socket** — Results are now
  returned as the evaluated expression's value (base64-encoded JSON) instead of
  via `puts`. End-to-end testing against a live rdbg-attached process showed the
  debug socket does not forward the debuggee's stdout, so the previous
  `puts(x.to_json)` path returned nothing — this also fixes `trigger_request`'s
  `Rails Events` section, which used the same mechanism.

### Documentation

- Corrected docs that claimed Rails tools are registered only when a Rails process is
  detected — they are always registered and guard themselves via `require_rails!`.

## 0.2.1 — 2026-06-17

### Bug Fixes

- **Fix `list_files` with explicit `session_id`** — `list_files` used an outdated
  `SessionManager#get` call path when a session ID was provided, causing
  `NoMethodError` instead of listing files. It now uses the same
  `SessionManager#client(session_id)` API as other tools.

## 0.2.0 — 2026-05-14

### Features

- **Structured Rails event capture in `trigger_request`** — The response now includes
  a `Rails Events` section with SQL queries, rendered templates, cache operations,
  enqueued jobs, and request lifecycle info, sourced from `ActiveSupport::Notifications`.
  LLM agents can detect N+1 queries, verify cache effectiveness, and track side-effects
  using structured data instead of parsing log text.

  How it works: debug-mcp injects a subscriber into the Rails process via `evaluate_code`
  at first use (idempotent, no gem install needed in the Rails app), tags HTTP requests
  with an auto-generated `X-Request-Id`, and correlates the captured events back to the
  triggering request. Events live in a per-process ring buffer (1000 events) protected
  by a Mutex.

- **Source tagging to separate app execution from debugger inspection** — When
  `evaluate_code` or `inspect_object` is used at a breakpoint, the AR queries they
  fire run on the request thread. Those events are tagged `source: :debug_eval` so
  they don't appear to be part of application execution. The default view shows only
  `:request` events; pass `include_debug_eval: true` to `trigger_request` to see all.
  Implemented via `Thread.current[:_debug_mcp_event_source]` with save/restore so
  nested wrapping is safe.

- **New `trigger_request` options** — `event_limits` (per-category count overrides;
  defaults `sql: 30, render: 20, cache: 20, job: unlimited, logger: 50`; pass `null`
  to disable a limit) and `include_debug_eval` (boolean) for tuning the event output.

### Bug Fixes (pre-release)

- **`SourceTagging.wrap` nested-safety** — The initial implementation saved the
  prior Thread-local value in a local variable, which a nested wrap within the
  same eval overwrote, causing the outer's `ensure` to restore the wrong value.
  Switched to a Thread-local stack (`:_debug_mcp_event_source_stack`) so each
  push/pop pair restores the correct prior source regardless of nesting depth.
  Discovered during real-Rails verification before the 0.2.0 release.

### Internal

- New modules: `DebugMcp::NotificationsSubscriber`, `DebugMcp::EventFormatter`,
  `DebugMcp::SourceTagging`.
- `evaluate_code` and `inspect_object` now wrap user expressions with `SourceTagging.wrap`.

## Renamed: `girb-mcp` → `debug-mcp` (2026-04-28)

This gem was previously released on RubyGems as `girb-mcp`. It has been renamed to
`debug-mcp` to better reflect its purpose: an MCP server for Ruby's debug gem.

The first `debug-mcp` release is **0.1.2** (see entry below for internal-namespace
changes). If you used `girb-mcp`, replace it with `debug-mcp` in your Gemfile and
MCP client config:

```ruby
# Gemfile
gem "debug-mcp"  # was: gem "girb-mcp"
```

```json
// MCP client config
{
  "mcpServers": {
    "debug-mcp": {                // was: "girb-mcp"
      "command": "debug-mcp",     // was: "girb-mcp"
      "args": []
    }
  }
}
```

The executable `girb-rails` was likewise renamed to `debug-rails`.

The version history for 0.1.0 and 0.1.1 below was originally published under the
name `girb-mcp`; the implementation is unchanged.

## 0.1.2 — 2026-04-28

First release under the `debug-mcp` name.

### Changes

- **Rename internal namespace from `girb` to `debug_mcp`** — Globals, symbols, and
  log paths injected into the debugged Ruby process are now namespaced with
  `debug_mcp` to match the gem name:
  - `$_girb_orig_int`, `$_girb_int_at` → `$_debug_mcp_orig_int`, `$_debug_mcp_int_at`
    (SIGINT trap save/restore)
  - `$__girb_err`, `$__girb_cap` → `$__debug_mcp_err`, `$__debug_mcp_cap`
    (`evaluate_code` error capture and stdout redirect)
  - `:girb_health_check` → `:debug_mcp_health_check` (force_reset health probe)
  - `/tmp/girb_debug.log` → `/tmp/debug_mcp.log` (internal debug log)

  This is internal to debug-mcp and does not change any public API. If you wrote
  Ruby code that read these globals from the debugged process directly, update
  the names accordingly.

- **Add `base64` runtime dependency** — `base64` was removed from Ruby's default
  gems in 3.4.0. `debug-mcp` uses `Base64.strict_encode64` to safely transmit
  multi-line / non-ASCII code over the debug gem's line-based protocol, so it is
  now declared explicitly in the gemspec to avoid `LoadError` on Ruby 3.4+.

## 0.1.1 — 2026-03-01

### Bug Fixes

- **Fix stale `pause` protocol messages causing session deadlock on remote connections** — For remote/Docker connections, `auto_repause!` sent 3–4 `pause PID\n` messages but only 1 was consumed; the rest accumulated in the debug gem's read buffer and fired as unexpected SIGURGs after `c` (continue), re-pausing the process with no client connected and blocking future connections. Fixed by adding a `check_paused` method that waits for the process to pause without sending a new `pause` message, and using it for all retry attempts in `auto_repause!`, `disconnect`, and `connect` (force_reset). Now only 1 `pause` message is sent per repause cycle.

- **Fix `auto_repause!` returning true while process is still running** — After `trigger_request` completes without hitting a breakpoint, `auto_repause!` reported success but `@paused` was actually `false`, causing all subsequent operations (`evaluate_code`, `set_breakpoint`, `disconnect`) to fail with "Process is not paused". Root cause: `attempt_trap_escape!` used passive `ensure_paused` (no SIGURG) instead of active `repause` when escape failed, leaving the process unpaused. Fixed by:
  - Using active `repause` in `attempt_trap_escape!` when escape fails
  - Adding recovery repause in `auto_repause!` after failed trap escape
  - Returning actual `client.paused` state from `attempt_repause_after_no_hit` instead of unconditional `true`

## 0.1.0 — 2026-03-01

Initial release.

### Features

- **MCP server** with STDIO and Streamable HTTP transports
- **21 debugging tools**: connect, evaluate_code, inspect_object, get_context, get_source, read_file, list_files, set_breakpoint, remove_breakpoint, continue_execution, step, next, finish, run_script, trigger_request, disconnect, and more
- **Rails integration**: auto-detected rails_info, rails_routes, rails_model tools
- **Docker support**: TCP and Unix socket connections with automatic remote file reading
- **Signal trap context handling**: auto-escape on connect and after trigger_request
- **Code safety checker**: warns about dangerous operations in evaluate_code
- **Session management**: multiple concurrent sessions with automatic timeout cleanup
- **debug-rails CLI**: launch Rails server with debug enabled in one command
