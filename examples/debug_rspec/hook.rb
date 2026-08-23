# frozen_string_literal: true

# debug-rspec hook — copy-paste snippet, see README.md for the workflow
#
# Loaded via `rspec --require`. Opens a debug session in nonstop mode
# (does not wait for a client) and installs catch breakpoints for test
# failure exceptions. When a failure is raised, the process suspends at
# the raise site — with the full stack and all runtime state intact —
# and waits for a debugger client (an AI agent via debug-mcp) to attach.
#
# Configuration (environment variables):
#   RUBY_DEBUG_OPEN / RUBY_DEBUG_HOST / RUBY_DEBUG_PORT / RUBY_DEBUG_NONSTOP
#                      Standard debug gem variables — set them when invoking
#                      rspec (see README.md for a ready-made command line).
#   DEBUG_RSPEC_CATCH  Comma-separated exception class names to catch.
#                      Default: RSpec::Expectations::ExpectationNotMetError
#                      Add specific error classes when hunting one,
#                      e.g. "RSpec::Expectations::ExpectationNotMetError,NoMethodError"
#
# Machine-verified facts (2026-07-05, debug 1.11.1 / rspec 3.13 / Ruby 3.4.8):
# - Catch breakpoints fire at raise time, BEFORE RSpec rescues the exception.
#   The failed example's frame is still on the stack; local variables and
#   instance state are inspectable, and fix hypotheses can be evaluated live.
# - Catch patterns are matched by name at raise time, so installing a catch
#   for RSpec::Expectations::ExpectationNotMetError before RSpec is loaded works.
# - After `continue`, RSpec rescues the exception and reports the failure
#   normally. The suspension is non-destructive.
# - Do NOT connect a setup client and hand off: disconnecting a client
#   auto-resumes the process (debug gem behavior), losing the pause.
#   That is why this hook installs catches in-process, with no client.

# Safety: pausing and waiting for a debugger would hang a CI job until its
# timeout. If a CI environment is detected, do nothing (tests run normally)
# unless the user explicitly opts in with DEBUG_RSPEC_FORCE=1.
if ENV["CI"] && ENV["DEBUG_RSPEC_FORCE"] != "1"
  warn "debug-rspec: CI environment detected — hook disabled (set DEBUG_RSPEC_FORCE=1 to override)"
  return
end

require "debug/open_nonstop"

catches = ENV.fetch("DEBUG_RSPEC_CATCH", "RSpec::Expectations::ExpectationNotMetError")
catches.split(",").map(&:strip).reject(&:empty?).each do |pattern|
  DEBUGGER__::SESSION.add_catch_breakpoint(pattern)
end
