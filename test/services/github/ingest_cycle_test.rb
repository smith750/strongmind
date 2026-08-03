require "test_helper"

module Github
  class IngestCycleTest < ActiveSupport::TestCase
    EVENTS_URL = "https://api.github.com/events?per_page=100"

    def repo_url(id)
      "https://api.github.com/repositories/#{id}"
    end

    def user_url(id)
      "https://api.github.com/user/#{id}"
    end

    def stub_events(headers = {})
      stub_request(:get, EVENTS_URL).to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" }.merge(headers))
    end

    def stub_repo(id, headers = {})
      stub_request(:get, repo_url(id)).to_return(status: 200, body: { id: id, full_name: "octocat/Hello-World" }.to_json, headers: { "X-RateLimit-Remaining" => "50" }.merge(headers))
    end

    def stub_user(id, headers = {})
      stub_request(:get, user_url(id)).to_return(status: 200, body: { id: id, login: "octocat" }.to_json, headers: { "X-RateLimit-Remaining" => "50" }.merge(headers))
    end

    def create_push_event(created_at:, github_repository_id: nil, github_actor_id: nil, repo_unenrichable: false, user_unenrichable: false, repository: nil)
      push_event = PushEvent.create!(
        github_event_id: SecureRandom.hex(4),
        github_repository_id: github_repository_id,
        github_actor_id: github_actor_id,
        repo_unenrichable: repo_unenrichable,
        user_unenrichable: user_unenrichable,
        repository: repository
      )
      push_event.update_columns(created_at: created_at)
      push_event
    end

    def poll_allowed_blocked_request(ratelimit_remaining: 50)
      Request.create!(purpose: :poll, url: "https://api.github.com/events", created_at: Time.current, poll_interval: 3600, ratelimit_remaining: ratelimit_remaining)
    end

    test "polls immediately when no Request has ever been made" do
      stub_events

      result = Github::IngestCycle.call

      assert_equal :poll, result.decision
      assert_requested :get, EVENTS_URL
      assert_not_nil result.request
    end

    test "does nothing and reports rate_limited when the remaining budget is at or below the safety floor" do
      Request.create!(purpose: :enrich_user, url: "https://api.github.com/user/1", created_at: Time.current, ratelimit_remaining: 5, ratelimit_reset: 1_700_000_000)

      result = Github::IngestCycle.call

      assert_equal :rate_limited, result.decision
      assert_equal 1_700_000_000, result.ratelimit_reset
      assert_not_requested :get, /api\.github\.com/
    end

    test "polls when the poll interval has elapsed and budget allows" do
      Request.create!(purpose: :poll, url: "https://api.github.com/events", created_at: 1.hour.ago, poll_interval: 60, ratelimit_remaining: 50)
      stub_events

      result = Github::IngestCycle.call

      assert_equal :poll, result.decision
      assert_requested :get, EVENTS_URL
    end

    test "enriches the oldest backlog item instead of polling when the poll interval hasn't elapsed" do
      poll_allowed_blocked_request
      repository = Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World")
      push_event = create_push_event(created_at: 1.hour.ago, github_actor_id: "111", repository: repository)
      stub_user("111")

      result = Github::IngestCycle.call

      assert_equal :enrich_user, result.decision
      assert_not_requested :get, EVENTS_URL
      assert_equal "111", push_event.reload.author.github_user_id
    end

    test "prioritizes repository enrichment over user enrichment when a backlog item needs both" do
      poll_allowed_blocked_request
      push_event = create_push_event(created_at: 1.hour.ago, github_repository_id: "222", github_actor_id: "111")
      stub_repo("222")
      stub_user("111")

      result = Github::IngestCycle.call

      assert_equal :enrich_repository, result.decision
      assert_requested :get, repo_url("222")
      assert_not_requested :get, user_url("111")
      assert_not_nil push_event.reload.repository_id
      assert_nil push_event.author_id
    end

    test "picks the globally oldest backlog item first" do
      poll_allowed_blocked_request
      newer = create_push_event(created_at: 30.minutes.ago, github_repository_id: "333")
      older = create_push_event(created_at: 2.hours.ago, github_repository_id: "222")
      stub_repo("222")
      stub_repo("333")

      Github::IngestCycle.call

      assert_not_nil older.reload.repository_id
      assert_nil newer.reload.repository_id
    end

    test "is idle when budget allows, poll interval hasn't elapsed, and there is no backlog" do
      poll_allowed_blocked_request

      result = Github::IngestCycle.call

      assert_equal :idle, result.decision
      assert_nil result.request
      assert_not_requested :get, /api\.github\.com/
    end

    test "excludes push events already marked unenrichable on both sides from the backlog" do
      poll_allowed_blocked_request
      create_push_event(created_at: 1.hour.ago, repo_unenrichable: true, user_unenrichable: true)

      result = Github::IngestCycle.call

      assert_equal :idle, result.decision
    end
  end
end
