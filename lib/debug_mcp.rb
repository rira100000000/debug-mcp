# frozen_string_literal: true

require_relative "debug_mcp/version"
require_relative "debug_mcp/debug_client"
require_relative "debug_mcp/session_manager"
require_relative "debug_mcp/exit_message_builder"
require_relative "debug_mcp/stop_event_annotator"
require_relative "debug_mcp/tcp_session_discovery"
require_relative "debug_mcp/source_tagging"
require_relative "debug_mcp/event_formatter"
require_relative "debug_mcp/notifications_subscriber"
require_relative "debug_mcp/server"

module DebugMcp
  class Error < StandardError; end

  class ConnectionError < Error
    attr_reader :final_output

    def initialize(message = nil, final_output: nil)
      super(message)
      @final_output = final_output
    end
  end

  class SessionError < Error
    attr_reader :final_output

    def initialize(message = nil, final_output: nil)
      super(message)
      @final_output = final_output
    end
  end

  class TimeoutError < Error
    attr_reader :final_output

    def initialize(message = nil, final_output: nil)
      super(message)
      @final_output = final_output
    end
  end
end
