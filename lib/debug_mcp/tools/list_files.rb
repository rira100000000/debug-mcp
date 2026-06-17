# frozen_string_literal: true

require "mcp"
require_relative "../rails_helper"

module DebugMcp
  module Tools
    class ListFiles < MCP::Tool
      MAX_ENTRIES = 500

      description "[Investigation] List files and directories in a path from the debug session's machine. " \
                  "Use this to explore directory structure, find source files, or locate configuration. " \
                  "Relative paths are resolved against the debugged process's working directory."

      annotations(
        title: "List Files",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          path: {
            type: "string",
            description: "Directory path to list (relative to working directory or absolute)",
          },
          pattern: {
            type: "string",
            description: "Optional glob pattern to filter entries (e.g., '*.rb', '**/*.yml'). " \
                         "When omitted, lists immediate children of the directory.",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
        required: ["path"],
      )

      class << self
        def call(path:, pattern: nil, session_id: nil, server_context:)
          client = get_client(server_context, session_id)

          if client&.remote
            return list_remote(client, path, pattern)
          end

          full_path = resolve_path(path, server_context, session_id)
          list_local(full_path, pattern)
        rescue DebugMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        def get_client(server_context, session_id)
          server_context[:session_manager].client(session_id)
        rescue DebugMcp::Error
          nil
        end

        def resolve_path(path, server_context, session_id)
          return File.expand_path(path) if path.start_with?("/") || path.start_with?("~")

          cwd = remote_cwd(server_context, session_id)
          if cwd
            File.join(cwd, path)
          else
            File.expand_path(path)
          end
        end

        def remote_cwd(server_context, session_id)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!
          result = client.send_command("p Dir.pwd")
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == "nil" || cleaned.empty?

          if cleaned.start_with?('"') && cleaned.end_with?('"')
            cleaned = cleaned[1..-2]
          end
          cleaned.empty? ? nil : cleaned
        rescue DebugMcp::Error
          nil
        end

        def list_local(full_path, pattern)
          unless Dir.exist?(full_path)
            return MCP::Tool::Response.new([{ type: "text",
              text: "Error: Directory not found: #{full_path}" }])
          end

          if pattern
            glob_path = File.join(full_path, pattern)
            entries = Dir.glob(glob_path).sort
          else
            entries = Dir.children(full_path).sort.map { |name| File.join(full_path, name) }
          end

          format_entries(full_path, entries, pattern)
        end

        def list_remote(client, path, pattern)
          client.auto_repause!

          # Resolve relative path
          full_path = if path.start_with?("/")
            path
          else
            cwd = RailsHelper.eval_expr(client, "Dir.pwd")
            cwd ? File.join(cwd, path) : path
          end

          # Check directory exists
          exists = RailsHelper.eval_expr(client, "Dir.exist?(#{full_path.inspect})")
          unless exists == "true"
            return MCP::Tool::Response.new([{ type: "text",
              text: "Error: Directory not found on remote process: #{full_path}" }])
          end

          if pattern
            expr = "Dir.glob(File.join(#{full_path.inspect}, #{pattern.inspect})).sort.first(#{MAX_ENTRIES + 1})" \
                   ".map{|f| (File.directory?(f) ? 'd:' : 'f:') + f }.join(\"\\n\")"
          else
            expr = "Dir.children(#{full_path.inspect}).sort.first(#{MAX_ENTRIES + 1})" \
                   ".map{|n| f=File.join(#{full_path.inspect},n); (File.directory?(f) ? 'd:' : 'f:') + f }.join(\"\\n\")"
          end

          result = RailsHelper.eval_expr(client, expr)
          unless result
            return MCP::Tool::Response.new([{ type: "text",
              text: "Error: Failed to list directory on remote process: #{full_path}" }])
          end

          raw_entries = result.split("\n").reject(&:empty?)
          truncated = raw_entries.length > MAX_ENTRIES
          raw_entries = raw_entries.first(MAX_ENTRIES) if truncated

          lines = []
          raw_entries.each do |entry|
            if entry.start_with?("d:")
              lines << "[dir]  #{entry[2..]}"
            else
              lines << "[file] #{entry[2..]}"
            end
          end

          header = "#{full_path} (#{raw_entries.length} entries) [remote]"
          header += " (truncated to #{MAX_ENTRIES})" if truncated
          text = "#{header}\n\n#{lines.join("\n")}"

          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue DebugMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error listing remote directory: #{e.message}" }])
        end

        def format_entries(full_path, entries, pattern)
          truncated = entries.length > MAX_ENTRIES
          entries = entries.first(MAX_ENTRIES) if truncated

          lines = entries.map do |entry|
            if File.directory?(entry)
              "[dir]  #{entry}"
            else
              "[file] #{entry}"
            end
          end

          header = "#{full_path} (#{entries.length} entries)"
          header += " matching '#{pattern}'" if pattern
          header += " (truncated to #{MAX_ENTRIES})" if truncated
          text = "#{header}\n\n#{lines.join("\n")}"

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
