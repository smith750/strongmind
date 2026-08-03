require "test_helper"

module Github
  class EnrichRepositoryTest < ActiveSupport::TestCase
    def repo_url(github_repository_id)
      "https://api.github.com/repositories/#{github_repository_id}"
    end

    def repo_body(id: "222", full_name: "octocat/Hello-World")
      {
        id: id,
        full_name: full_name,
        html_url: "https://github.com/#{full_name}",
        description: "My first repository",
        url: "https://api.github.com/repos/#{full_name}",
        private: false
      }.to_json
    end

    def push_event_needing_enrichment(github_repository_id: "222")
      PushEvent.create!(github_event_id: SecureRandom.hex(4), github_repository_id: github_repository_id)
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

    test "creates a new Repository and links it as the push event's repository on a fresh 200" do
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      stub_request(:get, repo_url("222")).to_return(status: 200, body: repo_body(id: "222", full_name: "octocat/Hello-World"), headers: { "ETag" => "\"repo-etag\"" })

      assert_difference "Repository.count", 1 do
        Github::EnrichRepository.call(push_event)
      end

      repository = Repository.find_by(github_repository_id: "222")
      assert_equal "octocat/Hello-World", repository.full_name
      assert_equal "https://github.com/octocat/Hello-World", repository.html_url
      assert_equal "My first repository", repository.description
      assert_equal "https://api.github.com/repos/octocat/Hello-World", repository.url
      assert_equal "\"repo-etag\"", repository.last_etag
      assert_equal JSON.parse(repo_body(id: "222", full_name: "octocat/Hello-World")), JSON.parse(repository.full_info)

      push_event.reload
      assert_equal repository, push_event.repository
      assert_equal false, push_event.repo_unenrichable
    end

    test "does not send If-None-Match when no Repository is known yet" do
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      stub_request(:get, repo_url("222")).with { |request| !request.headers.key?("If-None-Match") }
        .to_return(status: 200, body: repo_body, headers: { "ETag" => "\"etag\"" })

      Github::EnrichRepository.call(push_event)

      assert_requested :get, repo_url("222")
    end

    test "sends If-None-Match from an already-known Repository and links without creating a duplicate on a 304" do
      existing_repo = Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World", last_etag: "\"known-etag\"")
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      stub_request(:get, repo_url("222")).with(headers: { "If-None-Match" => "\"known-etag\"" })
        .to_return(status: 304, body: "")

      assert_no_difference "Repository.count" do
        Github::EnrichRepository.call(push_event)
      end

      push_event.reload
      assert_equal existing_repo, push_event.repository
    end

    test "updates an already-known Repository's fields when a 200 comes back with fresh data" do
      Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World", last_etag: "\"stale-etag\"")
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      stub_request(:get, repo_url("222"))
        .to_return(status: 200, body: repo_body(id: "222", full_name: "octocat/Hello-World-Renamed"), headers: { "ETag" => "\"fresh-etag\"" })

      assert_no_difference "Repository.count" do
        Github::EnrichRepository.call(push_event)
      end

      repository = Repository.find_by(github_repository_id: "222")
      assert_equal "octocat/Hello-World-Renamed", repository.full_name
      assert_equal "\"fresh-etag\"", repository.last_etag

      push_event.reload
      assert_equal repository, push_event.repository
    end

    test "a second push event against an already-known repository links to the same Repository" do
      Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World", last_etag: "\"known-etag\"")
      first = push_event_needing_enrichment(github_repository_id: "222")
      second = push_event_needing_enrichment(github_repository_id: "222")
      stub_request(:get, repo_url("222")).to_return(status: 304, body: "")

      Github::EnrichRepository.call(first)
      Github::EnrichRepository.call(second)

      assert_equal 1, Repository.count
      assert_equal first.reload.repository, second.reload.repository
    end

    test "marks repo_unenrichable on a 4xx response and does not create a Repository" do
      push_event = push_event_needing_enrichment(github_repository_id: "999999")
      stub_request(:get, repo_url("999999")).to_return(status: 404, body: "")

      assert_no_difference "Repository.count" do
        Github::EnrichRepository.call(push_event)
      end

      push_event.reload
      assert_equal true, push_event.repo_unenrichable
      assert_nil push_event.repository_id
    end

    test "still records the Request for a 4xx response" do
      push_event = push_event_needing_enrichment(github_repository_id: "999999")
      stub_request(:get, repo_url("999999")).to_return(status: 404, body: "")

      assert_difference "Request.count", 1 do
        Github::EnrichRepository.call(push_event)
      end

      request = Request.last
      assert_equal "enrich_repo", request.purpose
      assert_equal 404, request.status_code
    end

    test "logs an error and leaves the push event retryable when the HTTP request fails" do
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      stub_request(:get, repo_url("222")).to_raise(Errno::ECONNREFUSED)

      logs = capture_logs do
        assert_no_difference [ "Repository.count", "Request.count" ] do
          Github::EnrichRepository.call(push_event)
        end
      end

      assert_match(/ERROR/, logs)
      push_event.reload
      assert_nil push_event.repository_id
      assert_equal false, push_event.repo_unenrichable
    end

    test "marks repo_unenrichable without any HTTP call when github_repository_id is blank" do
      push_event = push_event_needing_enrichment(github_repository_id: nil)

      logs = capture_logs do
        Github::EnrichRepository.call(push_event)
      end

      assert_match(/WARN/, logs)
      assert_not_requested :get, /api\.github\.com/
      push_event.reload
      assert_equal true, push_event.repo_unenrichable
    end

    test "is a no-op when the push event is already enriched" do
      repository = Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World")
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      push_event.update!(repository: repository)

      Github::EnrichRepository.call(push_event)

      assert_not_requested :get, /api\.github\.com/
    end

    test "is a no-op when the push event is already marked repo_unenrichable" do
      push_event = push_event_needing_enrichment(github_repository_id: "222")
      push_event.update!(repo_unenrichable: true)

      Github::EnrichRepository.call(push_event)

      assert_not_requested :get, /api\.github\.com/
    end
  end
end
