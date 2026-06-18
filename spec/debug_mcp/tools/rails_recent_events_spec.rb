# frozen_string_literal: true

RSpec.describe DebugMcp::Tools::RailsRecentEvents do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  let(:sql_event) do
    { name: "sql.active_record", seq: 4, duration_ms: 1.2,
      data: { sql: "SELECT 1", binds: [] }, source: "request" }
  end
  let(:job_event) do
    { name: "enqueue.active_job", seq: 5, duration_ms: 0.3,
      data: { job_class: "MyJob", queue_name: "default", arguments: [] }, source: "request" }
  end
  let(:metadata) do
    { version: "2", installed: true, installed_at: 1000.0, buffer_started_at: 999.0,
      buffer_size: 2, buffer_max: 1000, dropped_count: 0, oldest_seq: 4, newest_seq: 5,
      next_seq: 5, subscriptions_count: 12 }
  end

  before do
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
    allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(false)
    allow(DebugMcp::NotificationsSubscriber).to receive(:install).with(client).and_return(true)
    allow(DebugMcp::NotificationsSubscriber).to receive(:metadata).with(client).and_return(metadata)
    allow(DebugMcp::NotificationsSubscriber).to receive(:fetch_last).and_return([sql_event, job_event])
    allow(DebugMcp::NotificationsSubscriber).to receive(:fetch_after_seq).and_return([job_event])
  end

  it "installs the subscriber and returns events with an observability header" do
    response = described_class.call(server_context: server_context)
    text = response_text(response)

    expect(DebugMcp::NotificationsSubscriber).to have_received(:install).with(client)
    expect(text).to include("=== Rails Recent Events ===")
    expect(text).to include("forward_only: true")
    expect(text).to include("paused_only: true")
    expect(text).to include("events_before_install_are_unavailable: true")
    expect(text).to include("seq range: 4..5")
    expect(text).to include("buffer: 2/1000 (dropped: 0)")
    expect(text).to include("## SQL")
    expect(text).to include("## Enqueued Jobs")
  end

  it "uses fetch_last by default with the requested limit" do
    described_class.call(limit: 25, server_context: server_context)
    expect(DebugMcp::NotificationsSubscriber).to have_received(:fetch_last).with(client, 25)
  end

  it "falls back to the default limit for non-positive values" do
    described_class.call(limit: 0, server_context: server_context)
    expect(DebugMcp::NotificationsSubscriber).to have_received(:fetch_last).with(client, described_class::DEFAULT_LIMIT)
  end

  it "uses the seq cursor when after_seq is given" do
    described_class.call(after_seq: 4, server_context: server_context)
    expect(DebugMcp::NotificationsSubscriber).to have_received(:fetch_after_seq).with(client, 4)
    expect(DebugMcp::NotificationsSubscriber).not_to have_received(:fetch_last)
  end

  it "filters by kind" do
    response = described_class.call(kinds: ["job"], server_context: server_context)
    text = response_text(response)

    expect(text).to include("filtered_kinds: job")
    expect(text).to include("## Enqueued Jobs")
    expect(text).not_to include("## SQL")
  end

  it "shows a clear note (with metadata) when no events match" do
    allow(DebugMcp::NotificationsSubscriber).to receive(:fetch_last).and_return([])
    response = described_class.call(server_context: server_context)
    text = response_text(response)

    expect(text).to include("=== Rails Recent Events ===")
    expect(text).to include("no matching events captured since the subscriber was installed")
  end

  it "is unavailable in trap context with a hint" do
    allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(true)
    response = described_class.call(server_context: server_context)
    text = response_text(response)

    expect(DebugMcp::NotificationsSubscriber).not_to have_received(:install)
    expect(text).to include("unavailable in trap context")
    expect(text).to include("trigger_request")
  end

  it "reports installed: true from the install result even if metadata comes back empty" do
    allow(DebugMcp::NotificationsSubscriber).to receive(:metadata).with(client).and_return({})
    response = described_class.call(server_context: server_context)
    text = response_text(response)

    # We just installed successfully, so the header must not claim otherwise,
    # even though the metadata round-trip returned nothing parseable.
    expect(text).to include("installed: true")
  end

  it "caps the after_seq cursor result by the requested limit" do
    many = Array.new(10) { |i| { name: "sql.active_record", seq: i + 1, duration_ms: 1, data: { sql: "S" }, source: "request" } }
    allow(DebugMcp::NotificationsSubscriber).to receive(:fetch_after_seq).and_return(many)
    expect(DebugMcp::EventFormatter).to receive(:format) do |events, **_|
      expect(events.size).to eq(3)
      "## SQL (3 queries)"
    end
    described_class.call(after_seq: 0, limit: 3, server_context: server_context)
  end

  it "reports when the subscriber could not be installed" do
    allow(DebugMcp::NotificationsSubscriber).to receive(:install).with(client).and_return(false)
    response = described_class.call(server_context: server_context)
    text = response_text(response)

    expect(text).to include("could not install the Notifications subscriber")
  end

  it "handles a non-Rails process" do
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
      .and_raise(DebugMcp::SessionError, "Not a Rails application")
    response = described_class.call(server_context: server_context)
    expect(response_text(response)).to include("Error: Not a Rails application")
  end

  it "excludes debug_eval events by default and includes them when asked" do
    response = described_class.call(server_context: server_context)
    expect(response_text(response)).to include("include_debug_eval: false")

    response = described_class.call(include_debug_eval: true, server_context: server_context)
    expect(response_text(response)).to include("include_debug_eval: true")
  end
end
