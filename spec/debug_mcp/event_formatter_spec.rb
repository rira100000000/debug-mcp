# frozen_string_literal: true

RSpec.describe DebugMcp::EventFormatter do
  describe ".format" do
    it "returns nil for empty events" do
      expect(described_class.format([])).to be_nil
      expect(described_class.format(nil)).to be_nil
    end

    it "formats a controller request section" do
      events = [
        {
          name: "start_processing.action_controller",
          timestamp: 1.0,
          duration_ms: 0.1,
          request_id: "abc",
          data: { controller: "UsersController", action: "show", method: "GET", path: "/users/1" },
        },
        {
          name: "process_action.action_controller",
          timestamp: 1.1,
          duration_ms: 35.4,
          request_id: "abc",
          data: {
            controller: "UsersController", action: "show", method: "GET", path: "/users/1",
            status: 200, view_runtime: 12.5, db_runtime: 4.2,
          },
        },
      ]
      out = described_class.format(events)
      expect(out).to include("## Request")
      expect(out).to include("GET /users/1 → UsersController#show")
      expect(out).to include("Status: 200")
      expect(out).to include("total 35.4ms")
      expect(out).to include("view 12.5ms")
      expect(out).to include("db 4.2ms")
    end

    it "formats SQL events with bind values" do
      events = [
        {
          name: "sql.active_record",
          duration_ms: 1.2,
          data: { sql: "SELECT * FROM users WHERE id = $1", query_name: "User Load", binds: ["1"], cached: false },
        },
      ]
      out = described_class.format(events)
      expect(out).to include("## SQL (1 query)")
      expect(out).to include("(1.2ms) User Load SELECT * FROM users WHERE id = $1")
      expect(out).to include("binds: 1")
    end

    it "marks cached SQL queries" do
      events = [
        {
          name: "sql.active_record",
          duration_ms: 0.1,
          data: { sql: "SELECT 1", query_name: "", binds: [], cached: true },
        },
      ]
      expect(described_class.format(events)).to include("[cached]")
    end

    it "truncates long SQL queries" do
      long_sql = "SELECT " + ("x" * 600) + " FROM t"
      events = [
        { name: "sql.active_record", duration_ms: 1.0,
          data: { sql: long_sql, query_name: "", binds: [], cached: false } },
      ]
      out = described_class.format(events)
      expect(out).to include("[truncated")
      expect(out.length).to be < long_sql.length + 200
    end

    it "applies SQL limit and reports truncated count" do
      events = (1..40).map do |i|
        { name: "sql.active_record", duration_ms: 0.1,
          data: { sql: "SELECT #{i}", query_name: "", binds: [], cached: false } }
      end
      out = described_class.format(events)
      expect(out).to include("## SQL (40 queries)")
      expect(out).to include("... and 10 more (limit=30)")
    end

    it "formats render events and shortens absolute paths" do
      events = [
        {
          name: "render_template.action_view",
          duration_ms: 12.3,
          data: { identifier: "/Users/foo/myapp/app/views/users/show.html.erb", layout: "layouts/application" },
        },
      ]
      out = described_class.format(events)
      expect(out).to include("## Renders (1)")
      expect(out).to include("[template] app/views/users/show.html.erb")
      expect(out).to include("layout=layouts/application")
      expect(out).not_to include("/Users/foo/myapp")
    end

    it "formats cache events with hit/miss" do
      events = [
        { name: "cache_read.active_support", duration_ms: 0.5,
          data: { key: "user/1", hit: true, store: "MemoryStore" } },
        { name: "cache_read.active_support", duration_ms: 0.3,
          data: { key: "user/2", hit: false, store: "MemoryStore" } },
      ]
      out = described_class.format(events)
      expect(out).to include("## Cache (2)")
      expect(out).to include("[read hit] user/1")
      expect(out).to include("[read miss] user/2")
    end

    it "formats enqueued jobs" do
      events = [
        {
          name: "enqueue.active_job",
          duration_ms: 1.0,
          data: { job_class: "WelcomeMailer", queue_name: "default", arguments: ["1", "user@example.com"] },
        },
      ]
      out = described_class.format(events)
      expect(out).to include("## Enqueued Jobs (1)")
      expect(out).to include("WelcomeMailer [default]")
      expect(out).to include("args=1, user@example.com")
    end

    it "renders multiple sections in expected order" do
      events = [
        { name: "process_action.action_controller", duration_ms: 50.0,
          data: { controller: "C", action: "a", method: "GET", path: "/", status: 200 } },
        { name: "sql.active_record", duration_ms: 1.0,
          data: { sql: "S", query_name: "", binds: [], cached: false } },
        { name: "render_template.action_view", duration_ms: 5.0,
          data: { identifier: "v.erb" } },
        { name: "cache_read.active_support", duration_ms: 0.1,
          data: { key: "k", hit: true } },
        { name: "enqueue.active_job", duration_ms: 0.5,
          data: { job_class: "J", queue_name: "q", arguments: [] } },
      ]
      out = described_class.format(events)
      idx_req = out.index("## Request")
      idx_sql = out.index("## SQL")
      idx_render = out.index("## Renders")
      idx_cache = out.index("## Cache")
      idx_job = out.index("## Enqueued Jobs")
      expect([idx_req, idx_sql, idx_render, idx_cache, idx_job]).to eq([idx_req, idx_sql, idx_render, idx_cache, idx_job].sort)
    end

    it "respects custom limits" do
      events = (1..10).map do |i|
        { name: "render_template.action_view", duration_ms: 1.0, data: { identifier: "v#{i}.erb" } }
      end
      out = described_class.format(events, limits: { sql: 30, render: 3, cache: 20, job: nil, logger: 50 })
      expect(out).to include("## Renders (10)")
      expect(out).to include("... and 7 more (limit=3)")
    end

    context "with source tagging (ADR-0003)" do
      let(:request_event) do
        { name: "sql.active_record", duration_ms: 1.0, source: :request,
          data: { sql: "SELECT 1 FROM users", query_name: "", binds: [], cached: false } }
      end
      let(:debug_eval_event) do
        { name: "sql.active_record", duration_ms: 0.5, source: :debug_eval,
          data: { sql: "PRAGMA table_xinfo(\"posts\")", query_name: "", binds: [], cached: false } }
      end

      it "excludes debug_eval events by default" do
        out = described_class.format([request_event, debug_eval_event])
        expect(out).to include("## SQL (1 query)")
        expect(out).to include("SELECT 1 FROM users")
        expect(out).not_to include("PRAGMA")
      end

      it "includes debug_eval events when include_debug_eval is true" do
        out = described_class.format([request_event, debug_eval_event], include_debug_eval: true)
        expect(out).to include("## SQL (2 queries)")
        expect(out).to include("SELECT 1 FROM users")
        expect(out).to include("PRAGMA")
      end

      it "returns nil when only debug_eval events remain after filtering" do
        out = described_class.format([debug_eval_event])
        expect(out).to be_nil
      end

      it "treats events without source as :request (string comparison)" do
        untagged = { name: "sql.active_record", duration_ms: 1.0,
                     data: { sql: "SELECT 1", query_name: "", binds: [], cached: false } }
        expect(described_class.format([untagged])).to include("SELECT 1")
      end
    end
  end
end
