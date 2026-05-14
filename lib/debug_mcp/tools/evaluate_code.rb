# frozen_string_literal: true

require "mcp"
require "base64"
require_relative "../code_safety_analyzer"
require_relative "../pending_http_helper"

module DebugMcp
  module Tools
    class EvaluateCode < MCP::Tool
      description "[Investigation] Execute Ruby code in the live context of the paused process. " \
                  "The code runs in the current binding — you can access local variables, " \
                  "call methods, inspect return values, or test fixes. " \
                  "stdout output (from puts, print, etc.) is automatically captured and returned " \
                  "(suppressed when it duplicates the return value). " \
                  "Example: evaluate_code(code: \"user.errors.full_messages\")"

      annotations(
        title: "Evaluate Ruby Code",
        read_only_hint: false,
        destructive_hint: true,
        idempotent_hint: false,
        open_world_hint: true,
      )

      input_schema(
        properties: {
          code: {
            type: "string",
            description: "Ruby code to execute (e.g., 'user.valid?', 'Order.where(status: :pending).count')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
          acknowledge_mutations: {
            type: "boolean",
            description: "Set to true to suppress data mutation warnings (e.g., .save, .create!) " \
                         "for the rest of this session. Other warning categories are unaffected.",
          },
        },
        required: ["code"],
      )

      class << self
        def call(code:, session_id: nil, acknowledge_mutations: nil, server_context:)
          manager = server_context[:session_manager]
          client = manager.client(session_id)
          client.auto_repause!

          # Acknowledge mutation warnings for this session if requested
          if acknowledge_mutations
            manager.acknowledge_warning(session_id, :mutation_operations)
          end

          # Layer 3: Code safety analysis — warn about dangerous operations
          safety_warnings = CodeSafetyAnalyzer.analyze(code)
          acknowledged = manager.acknowledged_warnings(session_id)
          safety_warnings = CodeSafetyAnalyzer.filter_acknowledged(safety_warnings, acknowledged)
          warning_text = CodeSafetyAnalyzer.format_warnings(safety_warnings)

          # In trap context (e.g., after SIGURG-based repause), `require` and
          # Mutex operations hang. Use a simplified evaluation path that avoids
          # stdout redirect (which needs `require "stringio"`).
          if client.trap_context
            return call_in_trap_context(client, code, warning_text: warning_text)
          end

          stdout_redirected = false
          suspended_catch_bps = []

          begin
            # Proactive recovery: if a previous timeout left $stdout redirected
            # to StringIO, restore it to the original STDOUT constant (immutable).
            begin
              client.send_command('$stdout = STDOUT if $stdout != STDOUT; nil')
            rescue DebugMcp::Error
              # Best-effort
            end

            # Proactive recovery: if a previous timeout left catch breakpoints
            # suspended (deleted but not restored), recreate them now.
            if client.suspended_catch_bps&.any?
              restore_catch_breakpoints(client, client.suspended_catch_bps)
              client.suspended_catch_bps = []
            end

            # Temporarily disable catch breakpoints to prevent them from
            # firing on exceptions raised during code evaluation
            suspended_catch_bps = suspend_catch_breakpoints(client)

            # Redirect $stdout to capture puts/print output.
            # Use StringIO directly (always available in debug gem sessions)
            # instead of `require "stringio"` which hangs in trap context.
            client.send_command(
              '$__debug_mcp_cap = StringIO.new; $stdout = $__debug_mcp_cap',
            )
            stdout_redirected = true

            # Evaluate user code (pp formats the return value)
            # The debug gem protocol is line-based, so multi-line code must be
            # encoded into a single line to avoid breaking the protocol.
            # The code is wrapped in begin/rescue to capture exceptions in
            # $__debug_mcp_err, allowing us to distinguish errors from normal nil.
            output = client.send_command(build_eval_command(code))

            # Restore $stdout and read captured output in a single round-trip
            captured = restore_and_read_stdout(client)
            stdout_redirected = false

            # Check if evaluation raised an exception
            err_info = read_eval_error(client)

            if err_info
              text = "Error: #{err_info}"
              text += "\n\nDebugger output:\n#{output}" if output && !output.strip.empty? && output.strip != "nil"
              text += "\n\nCaptured stdout:\n#{captured}" if captured
              if err_info.include?("ThreadError")
                text += "\n\nThis error occurs in signal trap context (common when connecting to Puma/Rails via SIGURG).\n" \
                        "Thread operations (Mutex, DB queries, model autoloading) are not available here.\n\n" \
                        "To escape trap context:\n" \
                        "  1. set_breakpoint on a line in your controller/action\n" \
                        "  2. trigger_request to send an HTTP request (this auto-resumes the process)\n" \
                        "  3. Once stopped at the breakpoint, all operations work normally"
              end
            elsif captured
              # pp() writes to $stdout, so captured stdout often contains
              # just the pp output of the return value (identical content).
              # Only show "Captured stdout" when it has additional content
              # (e.g., from puts/print in the evaluated code).
              return_val = output.strip.sub(/\A=> /, "")
              if captured.strip == return_val.strip
                text = output
              else
                text = "Return value:\n#{output}\n\nCaptured stdout:\n#{captured}"
              end
            else
              text = output
            end
            text = append_frame_info(client, text)
            text = append_trap_context_note(client, text)
            text = append_pending_http_note(client, text)
            text = prepend_warning(text, warning_text)
            MCP::Tool::Response.new([{ type: "text", text: text }])
          rescue DebugMcp::TimeoutError => e
            MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}\n\n" \
              "The code may be taking too long to execute. Consider:\n" \
              "- Breaking the expression into smaller parts\n" \
              "- Using 'run_debug_command' with a custom timeout" }])
          rescue DebugMcp::Error => e
            text = "Error: #{e.message}"
            if e.message.include?("ThreadError")
              text += "\n\nThis error occurs in signal trap context. " \
                      "Use set_breakpoint + trigger_request to escape to normal context first."
            end
            MCP::Tool::Response.new([{ type: "text", text: text }])
          ensure
            if stdout_redirected
              client.send_command('$stdout = STDOUT') rescue nil
            end
            # Save suspended catch BPs to client so they can be proactively
            # restored on the next evaluate_code call if this restore fails.
            client.suspended_catch_bps = suspended_catch_bps if suspended_catch_bps.any?
            restore_catch_breakpoints(client, suspended_catch_bps)
            client.suspended_catch_bps = []
          end
        end

        private

        # Simplified evaluation path for trap context (after SIGURG-based repause).
        # Avoids `require`, Mutex, and stdout redirect — all of which hang in trap context.
        # Only uses simple expressions that are safe in restricted context.
        def call_in_trap_context(client, code, warning_text: nil)
          # Use `p` instead of `pp` (pp may trigger autoload in some cases)
          # Use $__debug_mcp_err pattern (same as normal path) for structured error detection.
          # Single-line code only; multi-line code with newlines can't use Base64 (require hangs)
          if code.include?("\n")
            output = client.send_command(
              "$__debug_mcp_err=nil; p(begin; eval(#{code.gsub("\n", ";").inspect}); " \
              'rescue => __e; $__debug_mcp_err="#{__e.class}: #{__e.message}"; nil; end)',
            )
          else
            output = client.send_command(
              "$__debug_mcp_err=nil; p(begin; (#{code}); " \
              'rescue => __e; $__debug_mcp_err="#{__e.class}: #{__e.message}"; nil; end)',
            )
          end

          # Check for captured error (one additional round-trip, but safe in trap context)
          err_info = read_eval_error(client)

          if err_info
            text = "Error: #{err_info}"
            text += "\n\nDebugger output:\n#{output}" if output && !output.strip.empty? && output.strip != "nil"
            if err_info.include?("ThreadError")
              text += "\n\nThis error occurs in signal trap context (common when connecting to Puma/Rails via SIGURG).\n" \
                      "Thread operations (Mutex, DB queries, model autoloading) are not available here.\n\n" \
                      "To escape trap context:\n" \
                      "  1. set_breakpoint on a line in your controller/action\n" \
                      "  2. trigger_request to send an HTTP request (this auto-resumes the process)\n" \
                      "  3. Once stopped at the breakpoint, all operations work normally"
            end
          else
            text = output
          end

          text = append_trap_context_note(client, text)
          text = append_pending_http_note(client, text)
          text = prepend_warning(text, warning_text)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue DebugMcp::TimeoutError => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}\n\n" \
            "In trap context, some expressions may hang. Use simple expressions only.\n" \
            "To escape trap context: set_breakpoint + trigger_request." }])
        rescue DebugMcp::Error => e
          text = "Error: #{e.message}"
          text += "\n\n[trap context]" if client.trap_context
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        # Build a debug command that evaluates the given code.
        # The code is wrapped in begin/rescue to capture exceptions in
        # $__debug_mcp_err. On error, the rescue returns nil (which pp shows),
        # but the error is preserved in the global variable for structured
        # error reporting.
        # Base64-encoding is used when the code contains newlines (the debug
        # gem protocol is line-based) or non-ASCII characters (to avoid
        # encoding conflicts on the socket).
        def build_eval_command(code)
          # Tag any ActiveSupport::Notifications events fired during this eval
          # so trigger_request can filter them out (ADR-0003).
          # ensure clears the Thread-local even on exception.
          if code.include?("\n") || !code.ascii_only?
            encoded = Base64.strict_encode64(code.encode(Encoding::UTF_8))
            "$__debug_mcp_err=nil; pp(begin; require 'base64'; " \
            "Thread.current[:_debug_mcp_event_source]=:debug_eval; " \
            "eval(::Base64.decode64('#{encoded}').force_encoding('UTF-8'), binding); " \
            'rescue => __e; $__debug_mcp_err="#{__e.class}: #{__e.message}"; nil; ' \
            "ensure Thread.current[:_debug_mcp_event_source]=nil; end)"
          else
            "$__debug_mcp_err=nil; pp(begin; " \
            "Thread.current[:_debug_mcp_event_source]=:debug_eval; " \
            "(#{code}); " \
            'rescue => __e; $__debug_mcp_err="#{__e.class}: #{__e.message}"; nil; ' \
            "ensure Thread.current[:_debug_mcp_event_source]=nil; end)"
          end
        end

        # Check $__debug_mcp_err for a captured exception from the eval wrapper.
        # Returns "ClassName: message" string, or nil if no error.
        def read_eval_error(client)
          result = client.send_command("p $__debug_mcp_err")
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == "nil" || cleaned.empty?

          cleaned = cleaned[1..-2] if cleaned.start_with?('"') && cleaned.end_with?('"')
          cleaned.empty? ? nil : cleaned
        rescue DebugMcp::Error
          nil
        end

        # Restore $stdout and read captured output in a single command.
        # Combines two round-trips into one.
        def restore_and_read_stdout(client)
          result = client.send_command("$stdout = STDOUT; p $__debug_mcp_cap&.string")
          parse_captured_stdout(result)
        rescue DebugMcp::Error
          nil
        end

        def parse_captured_stdout(result)
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == '""' || cleaned == "nil" || cleaned.empty?

          # Remove surrounding quotes and unescape Ruby string escapes
          if cleaned.start_with?('"') && cleaned.end_with?('"')
            cleaned = cleaned[1..-2]
            cleaned = unescape_ruby_string(cleaned)
          end
          cleaned.empty? ? nil : cleaned
        end

        def unescape_ruby_string(str)
          str.gsub(/\\([nrt\\"'])/) do
            case $1
            when "n" then "\n"
            when "r" then "\r"
            when "t" then "\t"
            when "\\" then "\\"
            when '"' then '"'
            when "'" then "'"
            end
          end
        end

        # Prepend frame info if the debugger is not at frame 0 (i.e., after up/down).
        def append_frame_info(client, text)
          frame_output = client.send_command("frame", timeout: 3)
          # Debug gem output: "#1  ClassName#method at /path/to/file.rb:10" or similar
          if (match = frame_output.match(/#(\d+)\s+(.+)/))
            frame_num = match[1].to_i
            return "Frame ##{frame_num}: #{match[2].strip}\n\n#{text}" if frame_num > 0
          end
          text
        rescue DebugMcp::Error
          text
        end

        # Prepend safety warning to response text if present.
        def prepend_warning(text, warning_text)
          return text unless warning_text

          "#{warning_text}\n\nThe code was executed. Result follows:\n---\n#{text}"
        end

        def append_trap_context_note(client, text)
          return text unless client.respond_to?(:trap_context) && client.trap_context
          "#{text}\n\n[trap context — stdout capture (puts/print) is not available; use expression return values instead]"
        end

        def append_pending_http_note(client, text)
          note = PendingHttpHelper.pending_http_note(client)
          note ? "#{text}\n\n#{note}" : text
        end

        # Temporarily remove all catch breakpoints by deleting them.
        # Returns an array of exception class names that were removed.
        # The debug gem does not support disable/enable, so we must
        # delete and recreate catch breakpoints.
        def suspend_catch_breakpoints(client)
          output = client.send_command("info break")
          suspended = []

          output.each_line do |line|
            next unless line.include?("BP - Catch")
            # Match: #1  BP - Catch  "NoMethodError"
            next unless (match = line.match(/#(\d+)\s+BP - Catch\s+"([^"]+)"/))

            bp_num = match[1]
            exception_class = match[2]
            client.send_command("delete #{bp_num}")
            suspended << exception_class
          end

          suspended
        rescue DebugMcp::Error
          []
        end

        # Recreate catch breakpoints that were previously suspended.
        def restore_catch_breakpoints(client, exception_classes)
          exception_classes.each do |exc_class|
            client.send_command("catch #{exc_class}")
          rescue DebugMcp::Error
            # Best-effort: session may have ended
          end
        end
      end
    end
  end
end
