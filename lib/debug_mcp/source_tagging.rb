# frozen_string_literal: true

module DebugMcp
  module SourceTagging
    SOURCE_KEY = ":_debug_mcp_event_source"
    DEBUG_EVAL_SOURCE = ":debug_eval"

    class << self
      # Wrap a Ruby expression so ActiveSupport::Notifications events fired
      # during its evaluation are tagged with source: :debug_eval.
      #
      # Nested wraps preserve any outer source via save/restore — important
      # because internal probes (rails?, route_summary, eval_expr, etc.) can
      # be invoked while a user-driven evaluate_code is already in flight.
      #
      # The wrapped expression evaluates to the same value as the original.
      def wrap(code)
        "begin; __debug_mcp_prev_src=Thread.current[#{SOURCE_KEY}]; " \
        "Thread.current[#{SOURCE_KEY}]=#{DEBUG_EVAL_SOURCE}; " \
        "(#{code}); " \
        "ensure Thread.current[#{SOURCE_KEY}]=__debug_mcp_prev_src; end"
      end
    end
  end
end
