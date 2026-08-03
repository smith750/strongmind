require "rails_helper"
require "rake"

Rails.application.load_tasks unless Rake::Task.task_defined?("ingest:once")

RSpec.describe "ingest:once rake task" do
  before do
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

  it "invokes Github::IngestCycle exactly once" do
    stub_request(:get, "https://api.github.com/events?per_page=100")
      .to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" })

    expect { Rake::Task["ingest:once"].invoke }.to change(Request, :count).by(1)
  end

  it "logs the cycle's decision" do
    stub_request(:get, "https://api.github.com/events?per_page=100")
      .to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" })

    logs = capture_logs { Rake::Task["ingest:once"].invoke }

    expect(logs).to match(/decision=poll/)
  end

  it "does not make any HTTP call when the cycle decides to idle" do
    Request.create!(purpose: :poll, url: "https://api.github.com/events", created_at: Time.current, poll_interval: 3600, ratelimit_remaining: 50)

    Rake::Task["ingest:once"].invoke

    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
  end
end
