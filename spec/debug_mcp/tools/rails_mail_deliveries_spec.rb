# frozen_string_literal: true

RSpec.describe DebugMcp::Tools::RailsMailDeliveries do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  # The tool transports its result as a base64 JSON blob on the `=> ` line.
  def stub_deliveries(obj)
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
    allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(false)
    allow(client).to receive(:send_command).with(kind_of(String), timeout: 15)
      .and_return(debug_eval_json(obj))
  end

  it "formats observable test deliveries with previews and attachment names" do
    stub_deliveries(
      observable: true, delivery_method: "test", total: 1,
      deliveries: [{
        index: 0, from: "a@x.com", to: "b@y.com", cc: "", bcc: "",
        subject: "Welcome", multipart: false, body_preview: "Hello there",
        body_truncated: false,
        attachments: [{ filename: "invoice.pdf", content_type: "application/pdf" }],
      }],
    )

    text = response_text(described_class.call(server_context: server_context))

    expect(text).to include("=== Rails Mail Deliveries ===")
    expect(text).to include("delivery_method: test")
    expect(text).to include("observable: true")
    expect(text).to include("## [0] Welcome")
    expect(text).to include("to: b@y.com")
    expect(text).to include("attachments: invoice.pdf (application/pdf)")
    expect(text).to include("body: Hello there")
  end

  it "warns that an empty list is not proof when not observable" do
    stub_deliveries(observable: false, delivery_method: "smtp", total: 0, deliveries: [])

    text = response_text(described_class.call(server_context: server_context))

    expect(text).to include("observable: false")
    expect(text).to include("does NOT prove no mail was sent")
    expect(text).to include("(no deliveries captured)")
  end

  it "marks truncated bodies" do
    stub_deliveries(
      observable: true, delivery_method: "test", total: 1,
      deliveries: [{ index: 0, from: "a", to: "b", cc: "", bcc: "", subject: "S",
                     multipart: true, body_preview: "partial", body_truncated: true, attachments: [] }],
    )

    expect(response_text(described_class.call(server_context: server_context))).to include("body: partial [truncated]")
  end

  it "reports when ActionMailer is not loaded" do
    stub_deliveries(observable: false, delivery_method: "(ActionMailer not loaded)", total: 0, deliveries: [])

    text = response_text(described_class.call(server_context: server_context))
    expect(text).to include("(ActionMailer not loaded)")
  end

  it "surfaces a script error" do
    stub_deliveries(error: "NoMethodError: boom")

    expect(response_text(described_class.call(server_context: server_context))).to include("Error: NoMethodError: boom")
  end

  it "is unavailable in trap context" do
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
    allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(true)

    text = response_text(described_class.call(server_context: server_context))
    expect(text).to include("unavailable in trap context")
    expect(text).to include("trigger_request")
  end

  it "passes the requested limit, include_body and preview length into the script" do
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
    allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(false)
    captured = nil
    allow(client).to receive(:send_command).with(kind_of(String), timeout: 15) do |cmd, **_|
      captured = Base64.decode64(cmd[/decode64\('([^']+)'\)/, 1])
      "{}"
    end

    described_class.call(limit: 3, include_body: true, body_preview_chars: 99, server_context: server_context)

    expect(captured).to include("last(3)")
    # include_body still caps the body (at MAX_BODY_CHARS), never unbounded
    expect(captured).to include("cap = true ? #{described_class::MAX_BODY_CHARS} : 99")
  end

  it "caps preview chars at the maximum" do
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
    allow(DebugMcp::RailsHelper).to receive(:trap_context?).with(client).and_return(false)
    captured = nil
    allow(client).to receive(:send_command).with(kind_of(String), timeout: 15) do |cmd, **_|
      captured = Base64.decode64(cmd[/decode64\('([^']+)'\)/, 1])
      "{}"
    end

    described_class.call(body_preview_chars: 999_999, server_context: server_context)
    expect(captured).to include("cap = false ? #{described_class::MAX_BODY_CHARS} : #{described_class::MAX_PREVIEW_CHARS}")
  end

  it "handles a non-Rails process" do
    allow(DebugMcp::RailsHelper).to receive(:require_rails!).with(client)
      .and_raise(DebugMcp::SessionError, "Not a Rails application")
    expect(response_text(described_class.call(server_context: server_context)))
      .to include("Error: Not a Rails application")
  end
end
