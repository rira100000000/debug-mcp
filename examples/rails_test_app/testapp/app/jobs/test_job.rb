# Dummy job used to exercise rails_recent_events (enqueue.active_job) and
# rails_jobs queue snapshots. Usage:
#   TestJob.perform_later("payload")
class TestJob < ApplicationJob
  queue_as :default

  def perform(*args)
    Rails.logger.info("TestJob performed with #{args.inspect}")
  end
end
