# frozen_string_literal: true

require "mcp"
require "yaml"
require_relative "../rails_helper"

module DebugMcp
  module Tools
    class RailsInfo < MCP::Tool
      description "[Investigation] Show Rails application overview: app name, Rails/Ruby versions, " \
                  "environment, and root path. Also shows database configuration and route count " \
                  "when available (these require escaping trap context first on Puma/threaded servers). " \
                  "Use this after connecting to a Rails process to quickly understand the application."

      annotations(
        title: "Rails App Info",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      SENSITIVE_KEYS = %w[password secret secret_key_base secret_key].freeze

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!
          RailsHelper.require_rails!(client)

          parts = []

          # App name, Rails version, environment
          parts << build_app_section(client)

          # Root path
          parts << build_root_section(client)

          # Database configuration
          parts << build_db_section(client)

          # Route summary
          parts << build_routes_section(client)

          # Runtime observability (delivery method, queue adapter, cache store)
          parts << build_observability_section(client)

          text = parts.compact.join("\n\n")

          if text.include?("(unavailable)")
            text += "\n\n#{RailsHelper::TRAP_CONTEXT_HINT}" if RailsHelper.trap_context?(client)
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue DebugMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        def build_app_section(client)
          lines = ["=== Rails Application ==="]

          app_name = eval_expr(client, "Rails.application.class.module_parent_name")
          lines << "App: #{app_name}" if app_name

          rails_version = eval_expr(client, "Rails::VERSION::STRING")
          rails_env = eval_expr(client, "Rails.env")
          if rails_version
            env_part = rails_env ? " (#{rails_env})" : ""
            lines << "Rails: #{rails_version}#{env_part}"
          end

          ruby_version = eval_expr(client, "RUBY_VERSION")
          lines << "Ruby: #{ruby_version}" if ruby_version

          lines.join("\n")
        end

        def build_root_section(client)
          root = eval_expr(client, "Rails.root.to_s")
          root ? "Root: #{root}" : nil
        end

        def build_db_section(client)
          code = build_db_script
          result = run_info_script(client, code)
          # Fall through to YAML fallback if result is an error message
          # (e.g., "Database:\n  Error: can't be called from trap context")
          return result if result && !result.include?("Error:")

          # Fallback: read database.yml directly (works in trap context)
          build_db_section_from_yaml(client)
        rescue DebugMcp::Error
          build_db_section_from_yaml(client)
        end

        def build_routes_section(client)
          code = build_routes_script
          result = run_info_script(client, code)
          result || "Routes:\n  (unavailable)"
        rescue DebugMcp::Error
          "Routes:\n  (unavailable)"
        end

        def run_info_script(client, code)
          RailsHelper.run_base64_script(client, code)
        end

        # Runtime observability: which side effects can be observed in this
        # process. Trap-safe (uses eval_expr). Values show "(unavailable)" when
        # they can't be read, which also triggers the trap-context hint.
        def build_observability_section(client)
          probe = RailsHelper.observability_probe(client)
          pid = eval_expr(client, "Process.pid")

          lines = ["=== Observability ==="]
          lines << "ActionMailer delivery_method: #{probe[:delivery_method]}"
          lines << "ActiveJob queue_adapter: #{probe[:queue_adapter]}"
          lines << "Cache store: #{probe[:cache_store]}"
          lines << "PID: #{pid}" if pid
          lines << "Note: sent mail is observable via 'rails_mail_deliveries' only when " \
                   "delivery_method is :test; recent Rails events via 'rails_recent_events'."
          lines.join("\n")
        end

        def eval_expr(client, expr)
          RailsHelper.eval_expr(client, expr)
        end

        # Fallback: read config/database.yml via the debug session's File.read.
        # File I/O works in trap context (no threads/mutex needed).
        # ERB tags are replaced with DYNAMIC since they can't be evaluated.
        def build_db_section_from_yaml(client)
          root = eval_expr(client, "Rails.root.to_s")
          return "Database:\n  (unavailable)" unless root

          rails_env = eval_expr(client, "Rails.env") || "development"
          yaml_path = "#{root}/config/database.yml"
          # Use RailsHelper.eval_expr which properly handles \n unescaping
          raw = RailsHelper.eval_expr(client, "File.read(#{yaml_path.inspect})")
          return "Database:\n  (unavailable)" unless raw

          parse_database_yaml(raw, rails_env)
        rescue StandardError
          "Database:\n  (unavailable)"
        end

        # Parse database.yml content, stripping ERB and extracting the current env config.
        def parse_database_yaml(raw_yaml, rails_env)
          # Replace ERB tags with placeholder
          sanitized = raw_yaml.gsub(/<%.*?%>/, "DYNAMIC")
          config = YAML.safe_load(sanitized, permitted_classes: [Symbol]) || {}
          env_config = config[rails_env] || config["default"] || config.values.first

          return "Database:\n  (unavailable)" unless env_config.is_a?(Hash)

          lines = ["Database: (from database.yml)"]
          env_config.each do |key, value|
            key_s = key.to_s
            val = SENSITIVE_KEYS.include?(key_s) ? "[FILTERED]" : value.to_s
            lines << "  #{key_s}: #{val}"
          end
          lines.join("\n")
        rescue Psych::SyntaxError
          "Database:\n  (unavailable — database.yml parse error)"
        end

        # Scripts return values instead of using puts.
        # In trap context, puts output is not captured by the debug gem,
        # but expression return values are always captured.
        def build_db_script
          sensitive_keys = SENSITIVE_KEYS.map { |k| "\"#{k}\"" }.join(", ")
          <<~RUBY
            begin
              if defined?(ActiveRecord::Base)
                config = ActiveRecord::Base.connection_db_config
                hash = config.configuration_hash
                sensitive = [#{sensitive_keys}]
                lines = ["Database:"]
                hash.each do |k, v|
                  key_s = k.to_s
                  val = sensitive.include?(key_s) ? "[FILTERED]" : v.to_s
                  lines << "  " + key_s + ": " + val
                end
                lines.join("\\n")
              end
            rescue => e
              "Database:\\n  Error: " + e.message
            end
          RUBY
        end

        def build_routes_script
          <<~RUBY
            begin
              routes = Rails.application.routes.routes
              count = routes.count { |r| !r.defaults[:controller].to_s.empty? }
              if count > 0
                "Routes: " + count.to_s + " defined (use 'rails_routes' for details)"
              else
                "Routes: none defined"
              end
            rescue => e
              "Routes: unable to load"
            end
          RUBY
        end
      end
    end
  end
end
