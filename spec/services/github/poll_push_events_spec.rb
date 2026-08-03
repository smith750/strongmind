require "rails_helper"

RSpec.describe Github::PollPushEvents do
  def events_url
    "https://api.github.com/events?per_page=100"
  end

  def push_event_payload(id: "1", repo_id: "222", actor_id: "111")
    {
      id: id,
      type: "PushEvent",
      actor: { id: actor_id, login: "octocat" },
      repo: { id: repo_id, name: "octocat/Hello-World" },
      payload: {
        push_id: 555,
        size: 1,
        ref: "refs/heads/main",
        head: "abc123",
        before: "def456"
      },
      public: true,
      created_at: "2026-08-02T12:00:00Z"
    }
  end

  def watch_event_payload(id: "2")
    { id: id, type: "WatchEvent", actor: { id: "111" }, repo: { id: "222" }, payload: {} }
  end

  def response_headers(overrides = {})
    {
      "ETag" => "\"abc123etag\"",
      "X-RateLimit-Remaining" => "59",
      "X-RateLimit-Reset" => "1700000000",
      "X-Poll-Interval" => "60"
    }.merge(overrides)
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

  it "sends per_page=100 to the events endpoint" do
    stub_request(:get, events_url).to_return(status: 200, body: "[]", headers: response_headers)

    Github::PollPushEvents.call

    expect(a_request(:get, events_url)).to have_been_made
  end

  it "saves a PushEvent for each PushEvent entry and ignores other event types" do
    body = [ push_event_payload(id: "1"), watch_event_payload(id: "2") ].to_json
    stub_request(:get, events_url).to_return(status: 200, body: body, headers: response_headers)

    expect { Github::PollPushEvents.call }.to change(PushEvent, :count).by(1)

    push_event = PushEvent.find_by(github_event_id: "1")
    expect(push_event).not_to be_nil
    expect(push_event.github_push_id).to eq("555")
    expect(push_event.github_repository_id).to eq("222")
    expect(push_event.github_actor_id).to eq("111")
    expect(push_event.ref).to eq("refs/heads/main")
    expect(push_event.head).to eq("abc123")
    expect(push_event.before).to eq("def456")
    expect(JSON.parse(push_event.full_info)).to eq(JSON.parse(push_event_payload(id: "1").to_json))

    expect(PushEvent.find_by(github_event_id: "2")).to be_nil
  end

  it "is idempotent when the same github_event_id is seen again in a later poll" do
    body = [ push_event_payload(id: "1") ].to_json
    stub_request(:get, events_url).to_return(status: 200, body: body, headers: response_headers)

    Github::PollPushEvents.call

    expect { Github::PollPushEvents.call }.not_to change(PushEvent, :count)
  end

  it "skips and warns on a push event missing an id" do
    malformed = push_event_payload.except(:id)
    body = [ malformed ].to_json
    stub_request(:get, events_url).to_return(status: 200, body: body, headers: response_headers)

    logs = capture_logs do
      expect { Github::PollPushEvents.call }.not_to change(PushEvent, :count)
    end

    expect(logs).to match(/WARN/)
  end

  it "persists a Request record with rate limit and etag headers from the response" do
    stub_request(:get, events_url).to_return(status: 200, body: "[]", headers: response_headers)

    expect { Github::PollPushEvents.call }.to change(Request, :count).by(1)

    request = Request.last
    expect(request.purpose).to eq("poll")
    expect(request.status_code).to eq(200)
    expect(request.etag).to eq("\"abc123etag\"")
    expect(request.ratelimit_remaining).to eq(59)
    expect(request.ratelimit_reset).to eq(1700000000)
    expect(request.poll_interval).to eq(60)
  end

  it "defaults poll_interval to 0 when the header is absent" do
    stub_request(:get, events_url).to_return(status: 200, body: "[]", headers: response_headers.except("X-Poll-Interval"))

    Github::PollPushEvents.call

    expect(Request.last.poll_interval).to eq(0)
  end

  it "sends If-None-Match using the etag from the most recent poll Request" do
    Request.create!(purpose: :poll, url: "https://api.github.com/events", etag: "\"previous-etag\"", created_at: 1.minute.ago, updated_at: 1.minute.ago)
    stub_request(:get, events_url).with(headers: { "If-None-Match" => "\"previous-etag\"" })
      .to_return(status: 304, body: "", headers: response_headers.except("ETag"))

    Github::PollPushEvents.call

    expect(a_request(:get, events_url).with(headers: { "If-None-Match" => "\"previous-etag\"" })).to have_been_made
  end

  it "does not attempt to parse the body on a 304 response, but still records the Request" do
    stub_request(:get, events_url).to_return(status: 304, body: "", headers: response_headers.except("ETag"))

    expect {
      expect { Github::PollPushEvents.call }.not_to change(PushEvent, :count)
    }.to change(Request, :count).by(1)

    expect(Request.last.status_code).to eq(304)
  end

  it "logs an error and does not persist a Request on a 5xx response" do
    stub_request(:get, events_url).to_return(status: 503, body: "")

    logs = capture_logs do
      expect { Github::PollPushEvents.call }.not_to change(Request, :count)
    end

    expect(logs).to match(/ERROR/)
  end

  it "logs an error and does not raise when the HTTP request itself fails" do
    stub_request(:get, events_url).to_raise(Errno::ECONNREFUSED)

    logs = capture_logs do
      expect { Github::PollPushEvents.call }.not_to change(Request, :count)
    end

    expect(logs).to match(/ERROR/)
  end
end
