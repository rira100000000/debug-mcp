# frozen_string_literal: true

require "mcp"
require_relative "../pending_http_helper"
require_relative "../source_tagging"

module DebugMcp
  module Tools
    class InspectObject < MCP::Tool
      description "[Investigation] Deep-inspect a Ruby object in the paused process. " \
                  "Returns the value, class, and instance variables. " \
                  "More detailed than evaluate_code — use this to understand an object's internal state."

      annotations(
        title: "Inspect Object",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          expression: {
            type: "string",
            description: "Variable name or Ruby expression to inspect (e.g., 'user', '@items.first')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
        required: ["expression"],
      )

      class << self
        def call(expression:, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!

          parts = []

          # User-supplied expressions can hit ActiveRecord and fire Notifications
          # events. Tag them as :debug_eval so trigger_request can filter them
          # out (ADR-0003).

          # RT 1: Get the pretty-printed value (primary - if this fails, expression is invalid)
          value_output = client.send_command("pp(#{DebugMcp::SourceTagging.wrap(expression)})")
          parts << "Value:\n#{value_output}"

          # RT 2: Get class + instance variables (+ class variables if Module) in a single command
          begin
            meta_expr = "[(#{expression}).class.to_s, (#{expression}).instance_variables, " \
                        "(#{expression}).is_a?(Module) ? (#{expression}).class_variables : nil]"
            meta_output = client.send_command("p(#{DebugMcp::SourceTagging.wrap(meta_expr)})")
            class_name, ivars, cvars = parse_meta(meta_output)
            parts << "Class: #{class_name}" if class_name
            parts << "Instance variables: #{ivars}" if ivars

            # RT 3: Get class variable values (only for Module/Class with class variables)
            if cvars && cvars != "[]"
              begin
                cvar_expr = "Hash[(#{expression}).class_variables.map{|v|" \
                            "[v,begin;(#{expression}).class_variable_get(v);rescue;'(error)';end]}]"
                cvar_values = client.send_command("pp(#{DebugMcp::SourceTagging.wrap(cvar_expr)})")
                parts << "Class variables:\n#{cvar_values}"
              rescue DebugMcp::TimeoutError
                parts << "Class variables: #{cvars}"
              end
            elsif cvars
              parts << "Class variables: #{cvars}"
            end
          rescue DebugMcp::TimeoutError
            parts << "Class: (timed out)"
            parts << "Instance variables: (timed out)"
          end

          text = parts.join("\n\n")
          text = append_trap_context_note(client, text)
          if (http_note = PendingHttpHelper.pending_http_note(client))
            text = "#{text}\n\n#{http_note}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue DebugMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        # Parse combined meta output: => ["ClassName", [:@ivar1, :@ivar2], [:@@cvar1] or nil]
        # Returns [class_name, ivars_string, cvars_string_or_nil] or falls back to raw output.
        def parse_meta(output)
          cleaned = output.strip.sub(/\A=> /, "")
          # Match: ["ClassName", [...], [...] or nil]
          if (match = cleaned.match(/\A\["([^"]*)",\s*(\[.*?\]),\s*(nil|\[.*?\])\]\z/))
            cvars = match[3] == "nil" ? nil : match[3]
            [match[1], match[2], cvars]
          else
            # Fallback: return raw output as class info
            [cleaned, nil, nil]
          end
        end

        def append_trap_context_note(client, text)
          return text unless client.respond_to?(:trap_context) && client.trap_context
          "#{text}\n\n[trap context]"
        end
      end
    end
  end
end
