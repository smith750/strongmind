require "test_helper"

module Github
  class PollPushEventsTest < ActiveSupport::TestCase
    EVENTS_URL = "https://api.github.com/events?per_page=100"

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

    test "sends per_page=100 to the events endpoint" do
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: "[]", headers: response_headers)

      Github::PollPushEvents.call

      assert_requested :get, EVENTS_URL
    end

    test "saves a PushEvent for each PushEvent entry and ignores other event types" do
      body = [ push_event_payload(id: "1"), watch_event_payload(id: "2") ].to_json
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: body, headers: response_headers)

      assert_difference "PushEvent.count", 1 do
        Github::PollPushEvents.call
      end

      push_event = PushEvent.find_by(github_event_id: "1")
      assert_not_nil push_event
      assert_equal "555", push_event.github_push_id
      assert_equal "222", push_event.github_repository_id
      assert_equal "111", push_event.github_actor_id
      assert_equal "refs/heads/main", push_event.ref
      assert_equal "abc123", push_event.head
      assert_equal "def456", push_event.before
      assert_equal JSON.parse(push_event_payload(id: "1").to_json), JSON.parse(push_event.full_info)

      assert_nil PushEvent.find_by(github_event_id: "2")
    end

    test "is idempotent when the same github_event_id is seen again in a later poll" do
      body = [ push_event_payload(id: "1") ].to_json
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: body, headers: response_headers)

      Github::PollPushEvents.call

      assert_no_difference "PushEvent.count" do
        Github::PollPushEvents.call
      end
    end

    test "skips and warns on a push event missing an id" do
      malformed = push_event_payload.except(:id)
      body = [ malformed ].to_json
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: body, headers: response_headers)

      logs = capture_logs do
        assert_no_difference "PushEvent.count" do
          Github::PollPushEvents.call
        end
      end

      assert_match(/WARN/, logs)
    end

    test "persists a Request record with rate limit and etag headers from the response" do
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: "[]", headers: response_headers)

      assert_difference "Request.count", 1 do
        Github::PollPushEvents.call
      end

      request = Request.last
      assert_equal "poll", request.purpose
      assert_equal 200, request.status_code
      assert_equal "\"abc123etag\"", request.etag
      assert_equal 59, request.ratelimit_remaining
      assert_equal 1700000000, request.ratelimit_reset
      assert_equal 60, request.poll_interval
    end

    test "defaults poll_interval to 0 when the header is absent" do
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: "[]", headers: response_headers.except("X-Poll-Interval"))

      Github::PollPushEvents.call

      assert_equal 0, Request.last.poll_interval
    end

    test "sends If-None-Match using the etag from the most recent poll Request" do
      Request.create!(purpose: :poll, url: "https://api.github.com/events", etag: "\"previous-etag\"", created_at: 1.minute.ago, updated_at: 1.minute.ago)
      stub_request(:get, EVENTS_URL).with(headers: { "If-None-Match" => "\"previous-etag\"" })
        .to_return(status: 304, body: "", headers: response_headers.except("ETag"))

      Github::PollPushEvents.call

      assert_requested :get, EVENTS_URL, headers: { "If-None-Match" => "\"previous-etag\"" }
    end

    test "does not attempt to parse the body on a 304 response, but still records the Request" do
      stub_request(:get, EVENTS_URL).to_return(status: 304, body: "", headers: response_headers.except("ETag"))

      assert_difference "Request.count", 1 do
        assert_no_difference "PushEvent.count" do
          Github::PollPushEvents.call
        end
      end

      assert_equal 304, Request.last.status_code
    end

    test "logs an error and does not persist a Request on a 5xx response" do
      stub_request(:get, EVENTS_URL).to_return(status: 503, body: "")

      logs = capture_logs do
        assert_no_difference "Request.count" do
          Github::PollPushEvents.call
        end
      end

      assert_match(/ERROR/, logs)
    end

    test "logs an error and does not raise when the HTTP request itself fails" do
      stub_request(:get, EVENTS_URL).to_raise(Errno::ECONNREFUSED)

      logs = capture_logs do
        assert_no_difference "Request.count" do
          Github::PollPushEvents.call
        end
      end

      assert_match(/ERROR/, logs)
    end
  end
end
