# frozen_string_literal: true

require "base64"
require_relative "source_tagging"

module DebugMcp
  module RailsHelper
    module_function

    # Verify that the connected process is a Rails application.
    # Raises SessionError if Rails is not defined.
    def require_rails!(client)
      result = client.send_command("p defined?(Rails)")
      unless result.strip.sub(/\A=> /, "").include?("constant")
        raise DebugMcp::SessionError, "Not a Rails application. This tool requires a connected Rails process."
      end
    end

    # Check if Rails is available without raising.
    # Returns true if the connected process has Rails loaded.
    def rails?(client)
      result = client.send_command("p defined?(Rails)")
      result.strip.sub(/\A=> /, "").include?("constant")
    rescue DebugMcp::Error
      false
    end

    # Check if the client is in signal trap context.
    # Returns true if thread operations are restricted.
    def trap_context?(client)
      client.respond_to?(:in_trap_context?) && client.in_trap_context?
    rescue DebugMcp::Error
      false
    end

    # --- Base64 script execution (NOT trap-safe) ---

    # Execute a multi-line Ruby script via Base64 encoding in the target process.
    # Returns the cleaned string result, or nil if the script returned nil/empty.
    # Raises DebugMcp::Error on communication failure.
    def run_base64_script(client, code, timeout: 15)
      encoded = Base64.strict_encode64(code.encode(Encoding::UTF_8))
      command = "require 'base64'; eval(::Base64.decode64('#{encoded}').force_encoding('UTF-8'))"
      output = client.send_command(command, timeout: timeout)
      clean_script_output(output)
    end

    # Clean debug gem output from a script that returns a string value.
    # Strips "=> " prefix, removes surrounding quotes, and unescapes \\n.
    def clean_script_output(output)
      cleaned = output.strip.sub(/\A=> /, "")
      return nil if cleaned == "nil" || cleaned.empty?

      if cleaned.start_with?('"') && cleaned.end_with?('"')
        cleaned = cleaned[1..-2].gsub('\\n', "\n").gsub('\\"', '"')
      end
      cleaned.empty? ? nil : cleaned
    end

    # --- Lightweight methods (trap-safe, no Base64/require/puts) ---

    # Evaluate a simple `p` expression and return the cleaned string result.
    # Uses `p` (not `puts`) because `p` output is captured as the expression
    # result by the debug gem, which works even in signal trap context.
    # Returns nil if the result is nil or evaluation fails.
    def eval_expr(client, expr)
      # Note: internal probes use simple expressions (Rails.root, Rails.env,
      # Dir.pwd, etc.) that don't fire ActiveSupport::Notifications events,
      # so SourceTagging.wrap isn't applied here. Tools that take arbitrary
      # user expressions (evaluate_code, inspect_object) handle tagging
      # themselves at the call site.
      result = client.send_command("p #{expr}")
      cleaned = result.strip.sub(/\A=> /, "")
      return nil if cleaned == "nil" || cleaned.empty?

      if cleaned.start_with?('"') && cleaned.end_with?('"')
        cleaned = cleaned[1..-2]
        cleaned = cleaned.gsub('\\n', "\n").gsub('\\"', '"').gsub("\\\\", "\\")
      end
      cleaned.empty? ? nil : cleaned
    rescue DebugMcp::Error
      nil
    end

    # Fetch routes using a single `p` expression (trap-safe).
    # Returns { count: Integer, lines: String } or nil on failure.
    def lightweight_routes(client, controller: nil, path: nil, limit: 200)
      filter_parts = ["r.defaults[:controller].to_s!=''"]
      filter_parts << "r.defaults[:controller].to_s.include?(#{controller.inspect})" if controller
      filter_parts << "r.path.spec.to_s.include?(#{path.inspect})" if path
      filter = filter_parts.join(" && ")

      count_output = eval_expr(client,
        "Rails.application.routes.routes.count{|r|r.defaults[:controller].to_s!=''}")
      return nil if count_output.nil? # eval failed — can't access routes

      count = count_output.to_i

      expr = "Rails.application.routes.routes.select{|r|#{filter}}." \
             "first(#{limit}).map{|r|" \
             "r.verb.to_s.ljust(7)+' '+" \
             "r.path.spec.to_s.sub('(.:format)','')+' '+" \
             "r.defaults[:controller].to_s+'#'+r.defaults[:action].to_s+" \
             "(r.name.to_s.empty? ? '' : '  ('+r.name.to_s+')')}.join(\"\\n\")"
      lines = eval_expr(client, expr)

      { count: count, lines: lines || "" }
    rescue DebugMcp::Error
      nil
    end

    # Fetch a compact route summary for connect output (trap-safe).
    # Returns { count: Integer, samples: [String] } or nil.
    def route_summary(client, limit: 5)
      count_output = eval_expr(client,
        "Rails.application.routes.routes.count{|r|r.defaults[:controller].to_s!=''}")
      return nil if count_output.nil?

      count = count_output.to_i

      sample_expr = "Rails.application.routes.routes.select{|r|r.defaults[:controller].to_s!=''}." \
                    "first(#{limit}).map{|r|" \
                    "r.verb.to_s.ljust(7)+' '+" \
                    "r.path.spec.to_s.sub('(.:format)','')+' '+" \
                    "r.defaults[:controller].to_s+'#'+r.defaults[:action].to_s}.join(\"\\n\")"
      samples = eval_expr(client, sample_expr)

      { count: count, samples: samples&.split("\n") || [] }
    rescue DebugMcp::Error
      nil
    end

    # List model files from app/models/ using Dir.glob (trap-safe).
    # Returns array of model file names (e.g., ["user", "post", "admin/account"]) or nil.
    def model_files(client)
      output = eval_expr(client,
        "Dir.glob(Rails.root.join('app','models','**','*.rb').to_s)." \
        "sort.map{|f|f.split('/models/').last.sub('.rb','')}.reject{|f|f=='application_record'}.join(', ')")
      return nil if output.nil? || output.empty?

      output.split(", ")
    rescue DebugMcp::Error
      nil
    end

    # Get the path to the Rails log file (trap-safe).
    # Returns the absolute path string or nil if not determinable.
    def log_file_path(client)
      root = eval_expr(client, "Rails.root.to_s")
      env = eval_expr(client, "Rails.env")
      return nil unless root && env

      "#{root}/log/#{env}.log"
    rescue DebugMcp::Error
      nil
    end

    TRAP_CONTEXT_HINT = "Note: The process may be in signal trap context (common with Puma). " \
                        "Set a breakpoint and use trigger_request to escape trap context first."
  end
end
