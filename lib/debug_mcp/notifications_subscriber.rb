# frozen_string_literal: true

require "base64"
require "json"
require_relative "rails_helper"

module DebugMcp
  module NotificationsSubscriber
    BUFFER_MAX = 1000

    # Bumped whenever INJECTION_CODE's structure changes so that an older buffer
    # module already injected into a long-running target process is replaced
    # instead of silently kept. The injected module exposes `.version` and the
    # injection guard re-defines the module when the versions differ.
    VERSION = "2"

    # Save-time caps applied inside the target process, before JSON encoding.
    # These bound transport size (the debug socket is line-oriented — see
    # parse_json_array) and limit how much raw SQL / path text we retain.
    STORE_SQL_MAX = 2000
    STORE_PATH_MAX = 1000

    SUBSCRIBED_EVENTS = %w[
      sql.active_record
      render_template.action_view
      render_partial.action_view
      render_collection.action_view
      cache_read.active_support
      cache_write.active_support
      cache_fetch_hit.active_support
      cache_generate.active_support
      cache_delete.active_support
      enqueue.active_job
      start_processing.action_controller
      process_action.action_controller
    ].freeze

    # Code injected (via Base64 eval) into the target process. It defines a
    # process-global ::DebugMcpNotificationsBuffer module that subscribes to
    # ActiveSupport::Notifications and buffers recent events.
    #
    # Lifecycle notes (these fix bugs found by machine verification):
    # - Module DEFINITION and subscriber ACTIVATION are separated. The
    #   `.install` call lives OUTSIDE the `unless defined?` guard and is always
    #   invoked, so a module that was defined but left with zero subscriptions
    #   (e.g. a previous install attempt raised in trap context) recovers on the
    #   next injection. `.install` itself is idempotent via `@subscriptions.any?`.
    # - Reads never block: `safe_read` uses Mutex#try_lock and falls back to a
    #   lockless read. A blocking `synchronize` would deadlock if a debugger-
    #   stopped thread is holding the mutex; the process is paused during reads,
    #   so no writer is actually running and a lockless read is safe.
    # - A version mismatch re-defines the module (after uninstalling the old one).
    INJECTION_CODE = <<~RUBY
      unless defined?(::DebugMcpNotificationsBuffer) &&
             ::DebugMcpNotificationsBuffer.respond_to?(:version) &&
             ::DebugMcpNotificationsBuffer.version == #{VERSION.inspect}
        if defined?(::DebugMcpNotificationsBuffer) && ::DebugMcpNotificationsBuffer.respond_to?(:uninstall)
          ::DebugMcpNotificationsBuffer.uninstall rescue nil
        end

        module ::DebugMcpNotificationsBuffer
          class << self
            attr_reader :buffer, :subscriptions

            def version; #{VERSION.inspect}; end
            def buffer_max; #{BUFFER_MAX}; end
            def subscribed_events; #{SUBSCRIBED_EVENTS.inspect}.freeze; end

            def init!
              @buffer = []
              @subscriptions = []
              @mutex = Mutex.new
              @seq = 0
              @dropped = 0
              @installed_at = nil
              @buffer_started_at = Time.now.to_f
            end

            def push(event)
              @mutex.synchronize do
                @seq += 1
                event[:seq] = @seq
                @buffer << event
                while @buffer.size > buffer_max
                  @buffer.shift
                  @dropped += 1
                end
              end
            end

            # Read without ever blocking. If try_lock fails the mutex is held by
            # a debugger-stopped thread; we read locklessly (safe while paused).
            def safe_read
              locked = @mutex.try_lock
              begin
                yield
              ensure
                @mutex.unlock if locked
              end
            end

            def fetch_by_request_id(request_id)
              safe_read { @buffer.select { |e| e[:request_id] == request_id } }
            end

            def fetch_since(timestamp)
              safe_read { @buffer.select { |e| e[:timestamp] >= timestamp } }
            end

            def fetch_last(n)
              safe_read { @buffer.last(n) }
            end

            def fetch_after_seq(cursor)
              safe_read { @buffer.select { |e| e[:seq] > cursor } }
            end

            def clear
              @mutex.synchronize { @buffer.clear }
            end

            def metadata
              safe_read do
                {
                  version: version,
                  installed: @subscriptions.any?,
                  installed_at: @installed_at,
                  buffer_started_at: @buffer_started_at,
                  buffer_size: @buffer.size,
                  buffer_max: buffer_max,
                  dropped_count: @dropped,
                  oldest_seq: (@buffer.first && @buffer.first[:seq]),
                  newest_seq: (@buffer.last && @buffer.last[:seq]),
                  last_seq: @seq,
                  subscriptions_count: @subscriptions.size,
                }
              end
            end

            def install
              return if @subscriptions.any?

              callback = lambda do |name, started, finished, _id, payload|
                req_id = extract_request_id(name, payload)
                src = Thread.current[:_debug_mcp_event_source] || :request
                push({
                  name: name,
                  timestamp: started.to_f,
                  duration_ms: ((finished.to_f - started.to_f) * 1000).round(2),
                  request_id: req_id,
                  source: src,
                  data: sanitize_payload(name, payload),
                })
                Thread.current[:_debug_mcp_request_id] = nil if name == "process_action.action_controller"
              rescue StandardError
                # never raise from subscriber callback
              end

              subscribed_events.each do |event_name|
                @subscriptions << ::ActiveSupport::Notifications.subscribe(event_name, &callback)
              end
              @installed_at = Time.now.to_f
            end

            def uninstall
              @subscriptions.each { |s| ::ActiveSupport::Notifications.unsubscribe(s) }
              @subscriptions.clear
            end

            def extract_request_id(name, payload)
              return nil unless payload.is_a?(Hash)
              req_id = payload[:request_id]
              if name == "start_processing.action_controller" && payload[:headers]
                h = payload[:headers]
                req_id ||= safe_header_lookup(h, "action_dispatch.request_id")
                req_id ||= safe_header_lookup(h, "HTTP_X_REQUEST_ID")
                Thread.current[:_debug_mcp_request_id] = req_id if req_id
              end
              req_id || Thread.current[:_debug_mcp_request_id]
            end

            def safe_header_lookup(headers, key)
              headers[key]
            rescue StandardError
              nil
            end

            def sanitize_payload(name, payload)
              return {} unless payload.is_a?(Hash)
              case name
              when "sql.active_record"
                {
                  sql: truncate_text(payload[:sql].to_s, #{STORE_SQL_MAX}),
                  query_name: payload[:name].to_s,
                  cached: payload[:cached] ? true : false,
                  binds: safe_binds(payload[:type_casted_binds] || payload[:binds]),
                }
              when /\\Arender_/
                {
                  identifier: payload[:identifier].to_s,
                  layout: payload[:layout]&.to_s,
                  count: payload[:count],
                }
              when /\\Acache_/
                {
                  key: payload[:key].to_s[0, 200],
                  hit: payload[:hit],
                  store: payload[:store]&.to_s,
                }
              when "enqueue.active_job"
                job = payload[:job]
                {
                  job_class: (job.class.name rescue nil),
                  job_id: (job.respond_to?(:job_id) ? job.job_id : nil),
                  queue_name: (job.respond_to?(:queue_name) ? job.queue_name : nil),
                  arguments: (job.respond_to?(:arguments) ? job.arguments : []).map { |a| safe_inspect(a, 100) },
                }
              when "start_processing.action_controller", "process_action.action_controller"
                {
                  controller: payload[:controller],
                  action: payload[:action],
                  method: payload[:method],
                  path: truncate_text(payload[:path].to_s, #{STORE_PATH_MAX}),
                  format: payload[:format].to_s,
                  status: payload[:status],
                  view_runtime: payload[:view_runtime],
                  db_runtime: payload[:db_runtime],
                }
              else
                {}
              end
            rescue StandardError => e
              { error: "payload_sanitize_failed: \#{e.class}" }
            end

            def truncate_text(str, limit)
              return str if str.length <= limit
              str[0, limit] + "...[truncated \#{str.length - limit} chars]"
            rescue StandardError
              "<untruncatable>"
            end

            def safe_binds(binds)
              return [] unless binds.respond_to?(:each)
              binds.map { |b| safe_inspect(b, 100) }
            rescue StandardError
              []
            end

            def safe_inspect(obj, limit)
              s = obj.inspect
              s.length > limit ? s[0, limit] + "..." : s
            rescue StandardError
              "<uninspectable>"
            end
          end

          init!
        end
      end
      ::DebugMcpNotificationsBuffer.install
    RUBY

    class << self
      # Inject the subscriber into the Rails process and activate it. Idempotent.
      # Returns true on success, false otherwise.
      #
      # Returns false in signal trap context WITHOUT sending the injection: in
      # trap context ActiveSupport::Notifications.subscribe raises ThreadError
      # (Fanout#subscribe takes an internal mutex), and merely defining the
      # module there would leave it with zero subscriptions. We refuse early so
      # the caller can surface RailsHelper::TRAP_CONTEXT_HINT instead.
      def install(client)
        return false unless RailsHelper.rails?(client)
        return false if RailsHelper.trap_context?(client)

        encoded = Base64.strict_encode64(INJECTION_CODE)
        cmd = "p begin; require 'base64'; eval(::Base64.decode64('#{encoded}').force_encoding('UTF-8')); " \
              ":debug_mcp_subscriber_ok; rescue => __e; \"\#{__e.class}: \#{__e.message}\"; end"
        result = client.send_command(cmd)
        result.include?("debug_mcp_subscriber_ok")
      rescue DebugMcp::Error
        false
      end

      # Remove the subscriber. Best-effort; returns nil on error.
      def uninstall(client)
        client.send_command(
          "::DebugMcpNotificationsBuffer.uninstall if defined?(::DebugMcpNotificationsBuffer)",
        )
      rescue DebugMcp::Error
        nil
      end

      # Fetch events for a request_id. Returns array of event hashes (symbolized keys).
      def fetch_by_request_id(client, request_id)
        return [] unless request_id

        code = RailsHelper.json_command(
          "defined?(::DebugMcpNotificationsBuffer) ? " \
          "::DebugMcpNotificationsBuffer.fetch_by_request_id(#{request_id.inspect}).to_json : '[]'",
        )
        RailsHelper.decode_json_result(client.send_command(code), [])
      rescue DebugMcp::Error
        []
      end

      # Fetch events fired at-or-after the given timestamp.
      # Prefer fetch_last / fetch_after_seq: those are clock-independent, whereas
      # this compares against a client-supplied timestamp and is sensitive to
      # clock skew between the MCP host and the target process.
      def fetch_since(client, timestamp)
        code = RailsHelper.json_command(
          "defined?(::DebugMcpNotificationsBuffer) ? " \
          "::DebugMcpNotificationsBuffer.fetch_since(#{timestamp.to_f}).to_json : '[]'",
        )
        RailsHelper.decode_json_result(client.send_command(code), [])
      rescue DebugMcp::Error
        []
      end

      # Fetch the last n buffered events. Clock-independent.
      def fetch_last(client, n)
        code = RailsHelper.json_command(
          "defined?(::DebugMcpNotificationsBuffer) ? " \
          "::DebugMcpNotificationsBuffer.fetch_last(#{n.to_i}).to_json : '[]'",
        )
        RailsHelper.decode_json_result(client.send_command(code), [])
      rescue DebugMcp::Error
        []
      end

      # Fetch events with seq strictly greater than cursor. Clock-independent
      # cursor pagination — pass the previous response's newest_seq.
      def fetch_after_seq(client, cursor)
        code = RailsHelper.json_command(
          "defined?(::DebugMcpNotificationsBuffer) ? " \
          "::DebugMcpNotificationsBuffer.fetch_after_seq(#{cursor.to_i}).to_json : '[]'",
        )
        RailsHelper.decode_json_result(client.send_command(code), [])
      rescue DebugMcp::Error
        []
      end

      # Fetch subscriber metadata (version, installed_at, buffer_size,
      # dropped_count, seq cursors, ...). Returns {} if not installed.
      def metadata(client)
        code = RailsHelper.json_command(
          "defined?(::DebugMcpNotificationsBuffer) ? ::DebugMcpNotificationsBuffer.metadata.to_json : '{}'",
        )
        RailsHelper.decode_json_result(client.send_command(code), {})
      rescue DebugMcp::Error
        {}
      end
    end
  end
end
