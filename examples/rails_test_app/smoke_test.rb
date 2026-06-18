# frozen_string_literal: true

# Live smoke test for debug-mcp's Rails runtime observability.
#
# Unlike the gem's RSpec suite (which uses a stub debug client), this boots the
# real example Rails app and exercises the actual NotificationsSubscriber
# INJECTION_CODE, ActionMailer deliveries, and ActiveJob enqueueing against a
# live Rails process — the closest thing to what debug-mcp does over the debug
# socket, without the socket.
#
# Run it from the example app with its own bundle:
#
#   cd examples/rails_test_app/testapp
#   bundle install
#   RAILS_ENV=test bundle exec ruby ../smoke_test.rb
#
# Exits non-zero on the first failed assertion.

ENV["RAILS_ENV"] ||= "test"

require_relative "testapp/config/environment"

GEM_LIB = File.expand_path("../../lib", __dir__)
require File.join(GEM_LIB, "debug_mcp/notifications_subscriber")

$failures = 0
def check(condition, message)
  status = condition ? "[PASS]" : "[FAIL]"
  $failures += 1 unless condition
  puts "#{status} #{message}"
end

puts "=== debug-mcp Rails smoke test (Rails #{Rails::VERSION::STRING}, env=#{Rails.env}) ==="

# 1. Harness config makes side effects observable.
check(ActionMailer::Base.delivery_method == :test,
      "ActionMailer delivery_method is :test (#{ActionMailer::Base.delivery_method})")
check(ActiveJob::Base.queue_adapter_name == "test",
      "ActiveJob queue_adapter is :test (#{ActiveJob::Base.queue_adapter_name})")

# 2. The real INJECTION_CODE installs against real Rails and subscribes.
eval(DebugMcp::NotificationsSubscriber::INJECTION_CODE) # rubocop:disable Security/Eval
buffer = ::DebugMcpNotificationsBuffer
check(buffer.subscriptions.any?, "subscriber installed (#{buffer.subscriptions.size} subscriptions)")

# 3. Poison recovery: uninstall, then re-inject must resubscribe.
buffer.uninstall
check(buffer.subscriptions.empty?, "uninstall clears subscriptions")
eval(DebugMcp::NotificationsSubscriber::INJECTION_CODE) # rubocop:disable Security/Eval
check(buffer.subscriptions.any?, "re-injection re-subscribes after uninstall (poison recovery)")

# 4. A real job enqueue is captured with a monotonic seq.
ActiveJob::Base.queue_adapter.enqueued_jobs.clear
TestJob.perform_later("hello", 42)
enqueue = buffer.buffer.find { |e| e[:name] == "enqueue.active_job" }
check(!enqueue.nil?, "captured enqueue.active_job event")
check(enqueue && enqueue[:data][:job_class] == "TestJob",
      "captured job_class TestJob (#{enqueue && enqueue[:data][:job_class]})")
check(enqueue && enqueue[:seq].is_a?(Integer), "event carries a monotonic seq")
check(ActiveJob::Base.queue_adapter.enqueued_jobs.size >= 1,
      "TestAdapter enqueued_jobs populated (#{ActiveJob::Base.queue_adapter.enqueued_jobs.size})")

# 5. A real mailer delivery lands in ActionMailer::Base.deliveries.
ActionMailer::Base.deliveries.clear
TestMailer.with(to: "ada@example.com", name: "Ada").greeting.deliver_now
check(ActionMailer::Base.deliveries.size == 1,
      "delivery recorded in ActionMailer::Base.deliveries (#{ActionMailer::Base.deliveries.size})")
mail = ActionMailer::Base.deliveries.last
check(mail && mail.subject == "Hello Ada", "delivered subject is 'Hello Ada' (#{mail&.subject})")
check(mail && Array(mail.to).include?("ada@example.com"), "delivered to ada@example.com")

if $failures.zero?
  puts "\nALL PASS"
  exit 0
else
  puts "\n#{$failures} FAILURE(S)"
  exit 1
end
