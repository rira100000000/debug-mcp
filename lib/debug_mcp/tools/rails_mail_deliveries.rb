# frozen_string_literal: true

require "mcp"
require "base64"
require_relative "../rails_helper"

module DebugMcp
  module Tools
    # Read ActionMailer::Base.deliveries from the running process.
    #
    # Observability caveat (surfaced in every response): deliveries is only
    # populated when delivery_method is :test. With :smtp / :letter_opener / etc.
    # the array is usually empty, so an empty result is NOT proof that no mail
    # was sent — it may simply not be observable this way.
    #
    # PII: recipients, subject and body can contain personal data or secrets, and
    # Rails' filter_parameters does NOT apply to this path. Bodies are truncated
    # to a preview by default; attachment CONTENT is never returned (only name
    # and content type).
    class RailsMailDeliveries < MCP::Tool
      description "[Investigation] Show emails captured in ActionMailer::Base.deliveries (from, to, " \
                  "cc, bcc, subject, body preview, attachment names). Only populated when " \
                  "delivery_method is :test — with :smtp/:letter_opener the list is usually empty, so " \
                  "an empty result does NOT prove no mail was sent (the response says whether it is " \
                  "observable). Bodies are truncated by default and may contain PII; attachment content " \
                  "is never returned. Requires the process to be paused."

      annotations(
        title: "Rails Mail Deliveries",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      DEFAULT_LIMIT = 20
      MAX_LIMIT = 200
      DEFAULT_PREVIEW_CHARS = 500
      MAX_PREVIEW_CHARS = 5000
      # Hard ceiling applied even when include_body is true, so a multi-megabyte
      # body can never cross the line-oriented debug socket as one JSON line.
      MAX_BODY_CHARS = 50_000

      input_schema(
        properties: {
          limit: {
            type: "integer",
            description: "How many of the most recent deliveries to show (default: #{DEFAULT_LIMIT}).",
          },
          include_body: {
            type: "boolean",
            description: "Return more of the body (still capped at #{MAX_BODY_CHARS} chars) instead of " \
                         "a short preview. Off by default because bodies may contain PII/secrets.",
          },
          body_preview_chars: {
            type: "integer",
            description: "Preview length when include_body is false " \
                         "(default: #{DEFAULT_PREVIEW_CHARS}, max: #{MAX_PREVIEW_CHARS}).",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(limit: nil, include_body: false, body_preview_chars: nil, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!
          RailsHelper.require_rails!(client)

          # The probe iterates Mail objects and puts a JSON line; both need a
          # normal (non-trap) paused context.
          if RailsHelper.trap_context?(client)
            return text_response("Rails mail deliveries: unavailable in trap context.\n\n" \
                                 "#{RailsHelper::TRAP_CONTEXT_HINT}")
          end

          data = fetch_deliveries(
            client,
            limit: resolve_limit(limit),
            include_body: include_body ? true : false,
            preview_chars: resolve_preview(body_preview_chars),
          )

          if data.nil? || data.empty? || data[:error]
            msg = data && data[:error] ? "Error: #{data[:error]}" : "Rails mail deliveries: unavailable."
            msg += "\n\n#{RailsHelper::TRAP_CONTEXT_HINT}" if RailsHelper.trap_context?(client)
            return text_response(msg)
          end

          text_response(format_output(data))
        rescue DebugMcp::Error => e
          text_response("Error: #{e.message}")
        end

        private

        def resolve_limit(limit)
          n = limit.to_i
          n = DEFAULT_LIMIT unless n.positive?
          [n, MAX_LIMIT].min
        end

        def resolve_preview(chars)
          n = chars.to_i
          return DEFAULT_PREVIEW_CHARS unless n.positive?

          [n, MAX_PREVIEW_CHARS].min
        end

        def fetch_deliveries(client, limit:, include_body:, preview_chars:)
          script = build_script(limit: limit, include_body: include_body, preview_chars: preview_chars)
          encoded = Base64.strict_encode64(script)
          cmd = "require 'base64'; eval(::Base64.decode64('#{encoded}').force_encoding('UTF-8'))"
          result = client.send_command(cmd, timeout: 15)
          # The script's value is a base64 JSON blob (see build_script) — the
          # debug socket does not forward the debuggee's stdout, so we return the
          # data as the evaluated expression's value, not via puts.
          RailsHelper.decode_json_result(result, nil)
        rescue DebugMcp::Error
          nil
        end

        # Runs inside the target process. Truncates the body and strips newlines
        # there (not in the MCP layer) so the result stays small, and returns the
        # JSON base64-encoded as the script's value (send_command only sees the
        # evaluated value, not puts output).
        def build_script(limit:, include_body:, preview_chars:)
          <<~RUBY
            __result = begin
              if defined?(ActionMailer::Base)
                dm = ActionMailer::Base.delivery_method
                deliveries = ActionMailer::Base.deliveries
                shown = deliveries.last(#{limit})
                offset = deliveries.size - shown.size
                items = shown.map.with_index do |m, i|
                  raw = begin
                    if m.multipart?
                      part = m.text_part || m.html_part
                      part ? part.body.decoded.to_s : ""
                    else
                      m.body.decoded.to_s
                    end
                  rescue StandardError
                    ""
                  end
                  full_len = raw.length
                  cap = #{include_body} ? #{MAX_BODY_CHARS} : #{preview_chars}
                  shown = raw[0, cap].to_s.gsub(/\\s+/, " ").strip
                  atts = (m.attachments || []).map { |a|
                    { filename: a.filename.to_s[0, 200], content_type: a.content_type.to_s[0, 100] }
                  } rescue []
                  {
                    index: offset + i,
                    from: Array(m.from).join(", ")[0, 500],
                    to: Array(m.to).join(", ")[0, 1000],
                    cc: Array(m.cc).join(", ")[0, 1000],
                    bcc: Array(m.bcc).join(", ")[0, 1000],
                    subject: m.subject.to_s.gsub(/\\s+/, " ").strip[0, 500],
                    multipart: (m.multipart? rescue false),
                    body_preview: shown,
                    body_truncated: (full_len > cap),
                    attachments: atts,
                  }
                end
                { observable: (dm == :test), delivery_method: dm.to_s,
                  total: deliveries.size, deliveries: items }.to_json
              else
                { observable: false, delivery_method: "(ActionMailer not loaded)",
                  total: 0, deliveries: [] }.to_json
              end
            rescue => e
              { error: e.class.to_s + ": " + e.message }.to_json
            end
            [__result].pack("m0")
          RUBY
        end

        def format_output(data)
          lines = ["=== Rails Mail Deliveries ==="]
          lines << "delivery_method: #{data[:delivery_method]}"
          lines << "observable: #{data[:observable] ? true : false}"
          unless data[:observable]
            lines << "Note: deliveries is only populated when delivery_method is :test. " \
                     "An empty list does NOT prove no mail was sent."
          end
          lines << "total captured: #{data[:total]}"

          deliveries = data[:deliveries] || []
          if deliveries.empty?
            lines << "\n(no deliveries captured)"
            return lines.join("\n")
          end

          deliveries.each do |m|
            lines << ""
            lines << "## [#{m[:index]}] #{m[:subject]}"
            lines << "from: #{m[:from]}"
            lines << "to: #{m[:to]}"
            lines << "cc: #{m[:cc]}" unless m[:cc].to_s.empty?
            lines << "bcc: #{m[:bcc]}" unless m[:bcc].to_s.empty?
            lines << "multipart: #{m[:multipart]}"
            if (atts = m[:attachments]) && !atts.empty?
              names = atts.map { |a| "#{a[:filename]} (#{a[:content_type]})" }.join(", ")
              lines << "attachments: #{names}"
            end
            preview = m[:body_preview].to_s
            trunc = m[:body_truncated] ? " [truncated]" : ""
            lines << "body: #{preview}#{trunc}"
          end

          lines.join("\n")
        end

        def text_response(text)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
