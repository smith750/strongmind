require "test_helper"
require "rake"

Rails.application.load_tasks unless Rake::Task.task_defined?("ingest:once")

class IngestTaskTest < ActiveSupport::TestCase
  setup do
    Rake::Task["ingest:once"].reenable
  end

  def capture_logs
    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original_logger
  end

  test "invokes Github::IngestCycle exactly once" do
    stub_request(:get, "https://api.github.com/events?per_page=100")
      .to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" })

    assert_difference "Request.count", 1 do
      Rake::Task["ingest:once"].invoke
    end
  end

  test "logs the cycle's decision" do
    stub_request(:get, "https://api.github.com/events?per_page=100")
      .to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" })

    logs = capture_logs { Rake::Task["ingest:once"].invoke }

    assert_match(/decision=poll/, logs)
  end

  test "does not make any HTTP call when the cycle decides to idle" do
    Request.create!(purpose: :poll, url: "https://api.github.com/events", created_at: Time.current, poll_interval: 3600, ratelimit_remaining: 50)

    Rake::Task["ingest:once"].invoke

    assert_not_requested :get, /api\.github\.com/
  end
end
