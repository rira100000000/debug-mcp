# frozen_string_literal: true

require "base64"
require "json"
require_relative "rails_helper"

module DebugMcp
  module NotificationsSubscriber
    BUFFER_MAX = 1000

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

    INJECTION_CODE = <<~RUBY
      unless defined?(::DebugMcpNotificationsBuffer)
        module ::DebugMcpNotificationsBuffer
          BUFFER_MAX = #{BUFFER_MAX}
          SUBSCRIBED_EVENTS = #{SUBSCRIBED_EVENTS.inspect}.freeze

          @buffer = []
          @subscriptions = []
          @mutex = Mutex.new

          class << self
            attr_reader :buffer, :subscriptions

            def push(event)
              @mutex.synchronize do
                @buffer << event
                @buffer.shift while @buffer.size > BUFFER_MAX
              end
            end

            def fetch_by_request_id(request_id)
              @mutex.synchronize { @buffer.select { |e| e[:request_id] == request_id } }
            end

            def fetch_since(timestamp)
              @mutex.synchronize { @buffer.select { |e| e[:timestamp] >= timestamp } }
            end

            def clear
              @mutex.synchronize { @buffer.clear }
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

              SUBSCRIBED_EVENTS.each do |event_name|
                @subscriptions << ::ActiveSupport::Notifications.subscribe(event_name, &callback)
              end
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
                  sql: payload[:sql].to_s,
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
                  path: payload[:path],
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
        end
        ::DebugMcpNotificationsBuffer.install
      end
    RUBY

    class << self
      # Inject the subscriber into the Rails process. Idempotent.
      # Returns true on success, false otherwise.
      def install(client)
        return false unless RailsHelper.rails?(client)

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

        code = "puts(defined?(::DebugMcpNotificationsBuffer) ? " \
               "::DebugMcpNotificationsBuffer.fetch_by_request_id(#{request_id.inspect}).to_json : '[]')"
        result = client.send_command(code)
        parse_json_array(result)
      rescue DebugMcp::Error
        []
      end

      # Fetch events fired at-or-after the given timestamp.
      def fetch_since(client, timestamp)
        code = "puts(defined?(::DebugMcpNotificationsBuffer) ? " \
               "::DebugMcpNotificationsBuffer.fetch_since(#{timestamp.to_f}).to_json : '[]')"
        result = client.send_command(code)
        parse_json_array(result)
      rescue DebugMcp::Error
        []
      end

      private

      def parse_json_array(text)
        return [] unless text
        text.each_line do |line|
          stripped = line.strip
          next unless stripped.start_with?("[")
          begin
            parsed = JSON.parse(stripped, symbolize_names: true)
            return parsed if parsed.is_a?(Array)
          rescue JSON::ParserError
            next
          end
        end
        []
      end
    end
  end
end
