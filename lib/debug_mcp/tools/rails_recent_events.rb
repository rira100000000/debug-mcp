# frozen_string_literal: true

require "mcp"
require_relative "../rails_helper"
require_relative "../notifications_subscriber"
require_relative "../event_formatter"

module DebugMcp
  module Tools
    # Read recent Rails internal events (SQL, render, cache, job enqueue,
    # request lifecycle) from the in-process Notifications buffer, independent
    # of trigger_request.
    #
    # IMPORTANT semantics, surfaced in every response so the model does not
    # mistake "empty" for "nothing happened":
    # - forward-only: only events fired AFTER the subscriber was installed are
    #   visible. The first call installs the subscriber, so it usually returns
    #   little or nothing — that is not evidence that no SQL/jobs ran.
    # - paused-only: the target must be paused at a debugger prompt (we send
    #   commands over the debug socket).
    # - NOT read-only: installing the subscriber subscribes to
    #   ActiveSupport::Notifications inside the target — an in-process
    #   instrumentation side effect (no application data is written).
    class RailsRecentEvents < MCP::Tool
      description "[Investigation] Show recent Rails internal events (SQL, renders, cache, job " \
                  "enqueues, request lifecycle) captured from the running process, without needing " \
                  "trigger_request. FORWARD-ONLY: the first call installs an ActiveSupport::Notifications " \
                  "subscriber and only events fired AFTER that are visible — an empty result is NOT proof " \
                  "that nothing happened. Requires the process to be paused (set a breakpoint / use " \
                  "trigger_request first on threaded servers). Installing the subscriber is an in-process " \
                  "instrumentation side effect, so this tool is not strictly read-only."

      annotations(
        title: "Rails Recent Events",
        # Not read-only: installs an in-process Notifications subscriber.
        read_only_hint: false,
        destructive_hint: false,
        open_world_hint: false,
      )

      DEFAULT_LIMIT = 50
      MAX_LIMIT = 500

      input_schema(
        properties: {
          kinds: {
            type: "array",
            items: { type: "string", enum: %w[sql render cache job request] },
            description: "Filter to these event kinds (default: all). " \
                         "One or more of: sql, render, cache, job, request.",
          },
          limit: {
            type: "integer",
            description: "How many of the most recent buffered events to scan (default: #{DEFAULT_LIMIT}).",
          },
          after_seq: {
            type: "integer",
            description: "Cursor: return only events with seq greater than this. Use the previous " \
                         "response's newest_seq to page forward. Clock-independent (preferred over time).",
          },
          include_debug_eval: {
            type: "boolean",
            description: "Include events caused by debug-mcp's own evaluate_code/inspect_object calls " \
                         "(default: false).",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      KIND_MATCHERS = {
        "sql" => ->(name) { name == "sql.active_record" },
        "render" => ->(name) { name.start_with?("render_") },
        "cache" => ->(name) { name.start_with?("cache_") },
        "job" => ->(name) { name == "enqueue.active_job" },
        "request" => ->(name) { name.end_with?(".action_controller") },
      }.freeze

      class << self
        def call(kinds: nil, limit: nil, after_seq: nil, include_debug_eval: false, session_id: nil,
                 server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!
          RailsHelper.require_rails!(client)

          # Reads and install both send commands over the debug socket and both
          # take the buffer/Notifications mutex, which fails in trap context.
          if RailsHelper.trap_context?(client)
            return text_response("Rails recent events: unavailable in trap context.\n\n" \
                                 "#{RailsHelper::TRAP_CONTEXT_HINT}")
          end

          installed = NotificationsSubscriber.install(client)
          unless installed
            return text_response("Rails recent events: could not install the Notifications subscriber " \
                                 "in the target process.\n\n#{RailsHelper::TRAP_CONTEXT_HINT}")
          end

          limit = resolve_limit(limit)
          events = fetch_events(client, after_seq: after_seq, limit: limit)
          events = filter_by_kinds(events, kinds)
          metadata = NotificationsSubscriber.metadata(client)

          # `installed` is the result of the install we just performed — the only
          # trustworthy signal here. metadata[:installed] can be missing if the
          # metadata round-trip itself returned no parseable object.
          text_response(build_output(events, metadata, kinds, include_debug_eval, limit, installed))
        rescue DebugMcp::Error => e
          text_response("Error: #{e.message}")
        end

        private

        def resolve_limit(limit)
          n = limit.to_i
          n = DEFAULT_LIMIT unless n.positive?
          [n, MAX_LIMIT].min
        end

        def fetch_events(client, after_seq:, limit:)
          if after_seq
            # Forward cursor paging: oldest-after-cursor first, capped by limit
            # (target-side) so a busy buffer never dumps all 1000 events.
            NotificationsSubscriber.fetch_after_seq(client, after_seq.to_i, limit)
          else
            NotificationsSubscriber.fetch_last(client, limit)
          end
        end

        def filter_by_kinds(events, kinds)
          return events if kinds.nil? || kinds.empty?

          matchers = kinds.filter_map { |k| KIND_MATCHERS[k.to_s] }
          # All requested kinds were invalid: return nothing rather than silently
          # falling back to every event (which would expose more, not less).
          return [] if matchers.empty?

          events.select { |e| matchers.any? { |m| m.call(e[:name].to_s) } }
        end

        def build_output(events, metadata, kinds, include_debug_eval, limit, installed)
          header = build_metadata_header(metadata, kinds, include_debug_eval, installed)
          # Align EventFormatter's per-section display caps with the user's limit
          # so the "... and N more (limit=...)" note matches what was requested
          # instead of EventFormatter's internal defaults.
          limits = EventFormatter::DEFAULT_LIMITS.merge(
            sql: limit, render: limit, cache: limit, job: limit,
          )
          formatted = EventFormatter.format(events, limits: limits, include_debug_eval: include_debug_eval)

          body = if formatted.nil? || formatted.empty?
            "(no matching events captured since the subscriber was installed)"
          else
            formatted
          end

          "#{header}\n\n#{body}"
        end

        def build_metadata_header(metadata, kinds, include_debug_eval, installed)
          lines = ["=== Rails Recent Events ==="]
          lines << "installed: #{installed ? true : false}"
          lines << "forward_only: true (only events fired after install are visible)"
          lines << "paused_only: true"
          lines << "events_before_install_are_unavailable: true"
          lines << "installed_at: #{metadata[:installed_at] || "(unknown)"}"
          if metadata[:buffer_size]
            lines << "buffer: #{metadata[:buffer_size]}/#{metadata[:buffer_max]} " \
                     "(dropped: #{metadata[:dropped_count] || 0})"
          end
          if metadata[:oldest_seq] || metadata[:newest_seq]
            lines << "seq range: #{metadata[:oldest_seq] || "-"}..#{metadata[:newest_seq] || "-"}"
          end
          lines << "filtered_kinds: #{kinds && !kinds.empty? ? kinds.join(", ") : "all"}"
          lines << "include_debug_eval: #{include_debug_eval ? true : false}"
          lines.join("\n")
        end

        def text_response(text)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
