require "rails_helper"

RSpec.describe Github::EnrichRepository do
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

  it "creates a new Repository and links it as the push event's repository on a fresh 200" do
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    stub_request(:get, repo_url("222")).to_return(status: 200, body: repo_body(id: "222", full_name: "octocat/Hello-World"), headers: { "ETag" => "\"repo-etag\"" })

    expect { Github::EnrichRepository.call(push_event) }.to change(Repository, :count).by(1)

    repository = Repository.find_by(github_repository_id: "222")
    expect(repository.full_name).to eq("octocat/Hello-World")
    expect(repository.html_url).to eq("https://github.com/octocat/Hello-World")
    expect(repository.description).to eq("My first repository")
    expect(repository.url).to eq("https://api.github.com/repos/octocat/Hello-World")
    expect(repository.last_etag).to eq("\"repo-etag\"")
    expect(JSON.parse(repository.full_info)).to eq(JSON.parse(repo_body(id: "222", full_name: "octocat/Hello-World")))

    push_event.reload
    expect(push_event.repository).to eq(repository)
    expect(push_event.repo_unenrichable).to eq(false)
  end

  it "does not send If-None-Match when no Repository is known yet" do
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    stub_request(:get, repo_url("222")).with { |request| !request.headers.key?("If-None-Match") }
      .to_return(status: 200, body: repo_body, headers: { "ETag" => "\"etag\"" })

    Github::EnrichRepository.call(push_event)

    expect(a_request(:get, repo_url("222"))).to have_been_made
  end

  it "sends If-None-Match from an already-known Repository and links without creating a duplicate on a 304" do
    existing_repo = Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World", last_etag: "\"known-etag\"")
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    stub_request(:get, repo_url("222")).with(headers: { "If-None-Match" => "\"known-etag\"" })
      .to_return(status: 304, body: "")

    expect { Github::EnrichRepository.call(push_event) }.not_to change(Repository, :count)

    push_event.reload
    expect(push_event.repository).to eq(existing_repo)
  end

  it "updates an already-known Repository's fields when a 200 comes back with fresh data" do
    Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World", last_etag: "\"stale-etag\"")
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    stub_request(:get, repo_url("222"))
      .to_return(status: 200, body: repo_body(id: "222", full_name: "octocat/Hello-World-Renamed"), headers: { "ETag" => "\"fresh-etag\"" })

    expect { Github::EnrichRepository.call(push_event) }.not_to change(Repository, :count)

    repository = Repository.find_by(github_repository_id: "222")
    expect(repository.full_name).to eq("octocat/Hello-World-Renamed")
    expect(repository.last_etag).to eq("\"fresh-etag\"")

    push_event.reload
    expect(push_event.repository).to eq(repository)
  end

  it "links a second push event against an already-known repository to the same Repository" do
    Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World", last_etag: "\"known-etag\"")
    first = push_event_needing_enrichment(github_repository_id: "222")
    second = push_event_needing_enrichment(github_repository_id: "222")
    stub_request(:get, repo_url("222")).to_return(status: 304, body: "")

    Github::EnrichRepository.call(first)
    Github::EnrichRepository.call(second)

    expect(Repository.count).to eq(1)
    expect(second.reload.repository).to eq(first.reload.repository)
  end

  it "marks repo_unenrichable on a 4xx response and does not create a Repository" do
    push_event = push_event_needing_enrichment(github_repository_id: "999999")
    stub_request(:get, repo_url("999999")).to_return(status: 404, body: "")

    expect { Github::EnrichRepository.call(push_event) }.not_to change(Repository, :count)

    push_event.reload
    expect(push_event.repo_unenrichable).to eq(true)
    expect(push_event.repository_id).to be_nil
  end

  it "still records the Request for a 4xx response" do
    push_event = push_event_needing_enrichment(github_repository_id: "999999")
    stub_request(:get, repo_url("999999")).to_return(status: 404, body: "")

    expect { Github::EnrichRepository.call(push_event) }.to change(Request, :count).by(1)

    request = Request.last
    expect(request.purpose).to eq("enrich_repo")
    expect(request.status_code).to eq(404)
  end

  it "logs an error and leaves the push event retryable when the HTTP request fails" do
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    stub_request(:get, repo_url("222")).to_raise(Errno::ECONNREFUSED)

    logs = capture_logs do
      expect {
        expect { Github::EnrichRepository.call(push_event) }.not_to change(Repository, :count)
      }.not_to change(Request, :count)
    end

    expect(logs).to match(/ERROR/)
    push_event.reload
    expect(push_event.repository_id).to be_nil
    expect(push_event.repo_unenrichable).to eq(false)
  end

  it "marks repo_unenrichable without any HTTP call when github_repository_id is blank" do
    push_event = push_event_needing_enrichment(github_repository_id: nil)

    logs = capture_logs do
      Github::EnrichRepository.call(push_event)
    end

    expect(logs).to match(/WARN/)
    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
    push_event.reload
    expect(push_event.repo_unenrichable).to eq(true)
  end

  it "is a no-op when the push event is already enriched" do
    repository = Repository.create!(github_repository_id: "222", full_name: "octocat/Hello-World")
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    push_event.update!(repository: repository)

    Github::EnrichRepository.call(push_event)

    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
  end

  it "is a no-op when the push event is already marked repo_unenrichable" do
    push_event = push_event_needing_enrichment(github_repository_id: "222")
    push_event.update!(repo_unenrichable: true)

    Github::EnrichRepository.call(push_event)

    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
  end
end
