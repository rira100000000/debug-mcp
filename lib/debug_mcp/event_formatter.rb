# frozen_string_literal: true

module DebugMcp
  module EventFormatter
    DEFAULT_LIMITS = {
      sql: 30,
      render: 20,
      cache: 20,
      job: nil,           # nil = no limit
      logger: 50,
    }.freeze

    MAX_SQL_CHARS = 500
    SQL_HEAD = 300
    SQL_TAIL = 100
    MAX_CACHE_KEY_CHARS = 200
    MAX_JOB_ARG_CHARS = 300

    class << self
      # Format an array of event hashes (as returned by NotificationsSubscriber.fetch_*)
      # into a Markdown-flavored structured text block.
      # Returns nil if events is empty (after filtering).
      #
      # By default, events with source: :debug_eval are excluded — these are AR
      # queries / renders / etc. fired by debug-mcp's own evaluate_code calls
      # during breakpoint inspection (ADR-0003). Pass include_debug_eval: true
      # to keep them.
      def format(events, limits: DEFAULT_LIMITS, include_debug_eval: false)
        return nil if events.nil? || events.empty?

        filtered = include_debug_eval ? events : events.reject { |e| e[:source].to_s == "debug_eval" }
        return nil if filtered.empty?

        grouped = group_events(filtered)
        sections = []

        sections << format_controller(grouped[:controller])
        sections << format_sql(grouped[:sql], limit: limits[:sql])
        sections << format_renders(grouped[:render], limit: limits[:render])
        sections << format_cache(grouped[:cache], limit: limits[:cache])
        sections << format_jobs(grouped[:job], limit: limits[:job])

        sections.compact.join("\n\n")
      end

      private

      def group_events(events)
        groups = { controller: [], sql: [], render: [], cache: [], job: [] }
        events.each do |e|
          name = e[:name].to_s
          case name
          when "sql.active_record" then groups[:sql] << e
          when /\Arender_/         then groups[:render] << e
          when /\Acache_/          then groups[:cache] << e
          when "enqueue.active_job" then groups[:job] << e
          when "start_processing.action_controller", "process_action.action_controller"
            groups[:controller] << e
          end
        end
        groups
      end

      def format_controller(events)
        return nil if events.empty?
        finish = events.find { |e| e[:name] == "process_action.action_controller" }
        start = events.find { |e| e[:name] == "start_processing.action_controller" }
        target = finish || start
        return nil unless target

        data = target[:data] || {}
        lines = ["## Request"]
        lines << "#{data[:method]} #{data[:path]} → #{data[:controller]}##{data[:action]}"
        if finish
          status = data[:status]
          dur = finish[:duration_ms]
          extras = []
          extras << "view #{data[:view_runtime].round(1)}ms" if data[:view_runtime]
          extras << "db #{data[:db_runtime].round(1)}ms" if data[:db_runtime]
          extra_str = extras.any? ? " (#{extras.join(", ")})" : ""
          lines << "Status: #{status} — total #{dur}ms#{extra_str}"
        end
        lines.join("\n")
      end

      def format_sql(events, limit:)
        return nil if events.empty?
        shown, truncated = apply_limit(events, limit)
        lines = ["## SQL (#{events.size} #{events.size == 1 ? "query" : "queries"})"]
        shown.each_with_index do |e, i|
          d = e[:data] || {}
          dur = e[:duration_ms]
          cached = d[:cached] ? " [cached]" : ""
          name = d[:query_name].to_s.empty? ? "" : " #{d[:query_name]}"
          sql_text = truncate_sql(d[:sql].to_s)
          lines << "#{i + 1}. (#{dur}ms)#{cached}#{name} #{sql_text}"
          if d[:binds].is_a?(Array) && d[:binds].any?
            lines << "   binds: #{d[:binds].join(", ")}"
          end
        end
        lines << "... and #{truncated} more (limit=#{limit})" if truncated > 0
        lines.join("\n")
      end

      def format_renders(events, limit:)
        return nil if events.empty?
        shown, truncated = apply_limit(events, limit)
        lines = ["## Renders (#{events.size})"]
        shown.each_with_index do |e, i|
          d = e[:data] || {}
          kind = e[:name].to_s.sub("render_", "").sub(".action_view", "")
          dur = e[:duration_ms]
          identifier = d[:identifier].to_s
          # Shorten absolute paths to just the relative portion when possible
          identifier = identifier.sub(%r{\A.*?/app/views/}, "app/views/")
          extras = []
          extras << "layout=#{d[:layout]}" if d[:layout] && !d[:layout].to_s.empty?
          extras << "count=#{d[:count]}" if d[:count]
          extra_str = extras.any? ? " (#{extras.join(", ")})" : ""
          lines << "#{i + 1}. [#{kind}] #{identifier} — #{dur}ms#{extra_str}"
        end
        lines << "... and #{truncated} more (limit=#{limit})" if truncated > 0
        lines.join("\n")
      end

      def format_cache(events, limit:)
        return nil if events.empty?
        shown, truncated = apply_limit(events, limit)
        lines = ["## Cache (#{events.size})"]
        shown.each_with_index do |e, i|
          d = e[:data] || {}
          op = e[:name].to_s.sub("cache_", "").sub(".active_support", "")
          hit_marker = d[:hit] == true ? " hit" : d[:hit] == false ? " miss" : ""
          key = d[:key].to_s[0, MAX_CACHE_KEY_CHARS]
          lines << "#{i + 1}. [#{op}#{hit_marker}] #{key} (#{e[:duration_ms]}ms)"
        end
        lines << "... and #{truncated} more (limit=#{limit})" if truncated > 0
        lines.join("\n")
      end

      def format_jobs(events, limit:)
        return nil if events.empty?
        shown, truncated = apply_limit(events, limit)
        lines = ["## Enqueued Jobs (#{events.size})"]
        shown.each_with_index do |e, i|
          d = e[:data] || {}
          klass = d[:job_class] || "(unknown)"
          queue = d[:queue_name] ? " [#{d[:queue_name]}]" : ""
          args = (d[:arguments] || []).join(", ")[0, MAX_JOB_ARG_CHARS]
          arg_str = args.empty? ? "" : " args=#{args}"
          lines << "#{i + 1}. #{klass}#{queue}#{arg_str}"
        end
        lines << "... and #{truncated} more (limit=#{limit})" if truncated > 0
        lines.join("\n")
      end

      # Apply an item count limit. Returns [shown_array, truncated_count].
      # Pass limit=nil for no limit.
      def apply_limit(events, limit)
        return [events, 0] if limit.nil? || events.size <= limit
        [events.first(limit), events.size - limit]
      end

      def truncate_sql(sql)
        return sql if sql.length <= MAX_SQL_CHARS
        head = sql[0, SQL_HEAD]
        tail = sql[-SQL_TAIL, SQL_TAIL]
        "#{head} ... [truncated #{sql.length - SQL_HEAD - SQL_TAIL} chars] ... #{tail}"
      end
    end
  end
end
