require "test_helper"

module Github
  class EnrichUserTest < ActiveSupport::TestCase
    def user_url(github_actor_id)
      "https://api.github.com/user/#{github_actor_id}"
    end

    def user_body(id: "111", login: "octocat")
      {
        login: login,
        id: id,
        avatar_url: "https://avatars.githubusercontent.com/u/#{id}?",
        url: "https://api.github.com/users/#{login}",
        html_url: "https://github.com/#{login}",
        type: "User"
      }.to_json
    end

    def push_event_needing_enrichment(github_actor_id: "111")
      PushEvent.create!(github_event_id: SecureRandom.hex(4), github_actor_id: github_actor_id)
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

    test "creates a new User and links it as the push event's author on a fresh 200" do
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      stub_request(:get, user_url("111")).to_return(status: 200, body: user_body(id: "111", login: "octocat"), headers: { "ETag" => "\"user-etag\"" })

      assert_difference "User.count", 1 do
        Github::EnrichUser.call(push_event)
      end

      user = User.find_by(github_user_id: "111")
      assert_equal "octocat", user.login
      assert_equal "https://avatars.githubusercontent.com/u/111?", user.avatar_url
      assert_equal "https://api.github.com/users/octocat", user.user_url
      assert_equal "https://github.com/octocat", user.html_url
      assert_equal "\"user-etag\"", user.last_etag
      assert_equal JSON.parse(user_body(id: "111", login: "octocat")), JSON.parse(user.full_info)

      push_event.reload
      assert_equal user, push_event.author
      assert_equal false, push_event.user_unenrichable
    end

    test "does not send If-None-Match when no User is known yet" do
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      stub_request(:get, user_url("111")).with { |request| !request.headers.key?("If-None-Match") }
        .to_return(status: 200, body: user_body, headers: { "ETag" => "\"etag\"" })

      Github::EnrichUser.call(push_event)

      assert_requested :get, user_url("111")
    end

    test "sends If-None-Match from an already-known User and links without creating a duplicate on a 304" do
      existing_user = User.create!(github_user_id: "111", login: "octocat", last_etag: "\"known-etag\"")
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      stub_request(:get, user_url("111")).with(headers: { "If-None-Match" => "\"known-etag\"" })
        .to_return(status: 304, body: "")

      assert_no_difference "User.count" do
        Github::EnrichUser.call(push_event)
      end

      push_event.reload
      assert_equal existing_user, push_event.author
    end

    test "updates an already-known User's fields when a 200 comes back with fresh data" do
      User.create!(github_user_id: "111", login: "octocat", last_etag: "\"stale-etag\"")
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      stub_request(:get, user_url("111"))
        .to_return(status: 200, body: user_body(id: "111", login: "octocat-renamed"), headers: { "ETag" => "\"fresh-etag\"" })

      assert_no_difference "User.count" do
        Github::EnrichUser.call(push_event)
      end

      user = User.find_by(github_user_id: "111")
      assert_equal "octocat-renamed", user.login
      assert_equal "\"fresh-etag\"", user.last_etag

      push_event.reload
      assert_equal user, push_event.author
    end

    test "a second push event by an already-known author links to the same User" do
      User.create!(github_user_id: "111", login: "octocat", last_etag: "\"known-etag\"")
      first = push_event_needing_enrichment(github_actor_id: "111")
      second = push_event_needing_enrichment(github_actor_id: "111")
      stub_request(:get, user_url("111")).to_return(status: 304, body: "")

      Github::EnrichUser.call(first)
      Github::EnrichUser.call(second)

      assert_equal 1, User.count
      assert_equal first.reload.author, second.reload.author
    end

    test "marks user_unenrichable on a 4xx response and does not create a User" do
      push_event = push_event_needing_enrichment(github_actor_id: "999999")
      stub_request(:get, user_url("999999")).to_return(status: 404, body: "")

      assert_no_difference "User.count" do
        Github::EnrichUser.call(push_event)
      end

      push_event.reload
      assert_equal true, push_event.user_unenrichable
      assert_nil push_event.author_id
    end

    test "still records the Request for a 4xx response" do
      push_event = push_event_needing_enrichment(github_actor_id: "999999")
      stub_request(:get, user_url("999999")).to_return(status: 404, body: "")

      assert_difference "Request.count", 1 do
        Github::EnrichUser.call(push_event)
      end

      request = Request.last
      assert_equal "enrich_user", request.purpose
      assert_equal 404, request.status_code
    end

    test "logs an error and leaves the push event retryable when the HTTP request fails" do
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      stub_request(:get, user_url("111")).to_raise(Errno::ECONNREFUSED)

      logs = capture_logs do
        assert_no_difference [ "User.count", "Request.count" ] do
          Github::EnrichUser.call(push_event)
        end
      end

      assert_match(/ERROR/, logs)
      push_event.reload
      assert_nil push_event.author_id
      assert_equal false, push_event.user_unenrichable
    end

    test "marks user_unenrichable without any HTTP call when github_actor_id is blank" do
      push_event = push_event_needing_enrichment(github_actor_id: nil)

      logs = capture_logs do
        Github::EnrichUser.call(push_event)
      end

      assert_match(/WARN/, logs)
      assert_not_requested :get, /api\.github\.com/
      push_event.reload
      assert_equal true, push_event.user_unenrichable
    end

    test "is a no-op when the push event is already enriched" do
      user = User.create!(github_user_id: "111", login: "octocat")
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      push_event.update!(author: user)

      Github::EnrichUser.call(push_event)

      assert_not_requested :get, /api\.github\.com/
    end

    test "is a no-op when the push event is already marked user_unenrichable" do
      push_event = push_event_needing_enrichment(github_actor_id: "111")
      push_event.update!(user_unenrichable: true)

      Github::EnrichUser.call(push_event)

      assert_not_requested :get, /api\.github\.com/
    end
  end
end
