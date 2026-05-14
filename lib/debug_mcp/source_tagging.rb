# frozen_string_literal: true

module DebugMcp
  module SourceTagging
    SOURCE_KEY = ":_debug_mcp_event_source"
    STACK_KEY = ":_debug_mcp_event_source_stack"
    DEBUG_EVAL_SOURCE = ":debug_eval"

    class << self
      # Wrap a Ruby expression so ActiveSupport::Notifications events fired
      # during its evaluation are tagged with source: :debug_eval.
      #
      # Uses a Thread-local stack rather than a local variable so nested
      # wraps within a single eval are safe — each push/pop pair restores
      # the correct previous value even when wraps share the same call frame.
      #
      # The wrapped expression evaluates to the same value as the original.
      def wrap(code)
        "begin; " \
        "(::Thread.current[#{STACK_KEY}] ||= []) << ::Thread.current[#{SOURCE_KEY}]; " \
        "::Thread.current[#{SOURCE_KEY}]=#{DEBUG_EVAL_SOURCE}; " \
        "(#{code}); " \
        "ensure ::Thread.current[#{SOURCE_KEY}]=::Thread.current[#{STACK_KEY}].pop; end"
      end
    end
  end
end
