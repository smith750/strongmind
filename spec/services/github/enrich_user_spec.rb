require "rails_helper"

RSpec.describe Github::EnrichUser do
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

  it "creates a new User and links it as the push event's author on a fresh 200" do
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    stub_request(:get, user_url("111")).to_return(status: 200, body: user_body(id: "111", login: "octocat"), headers: { "ETag" => "\"user-etag\"" })

    expect { Github::EnrichUser.call(push_event) }.to change(User, :count).by(1)

    user = User.find_by(github_user_id: "111")
    expect(user.login).to eq("octocat")
    expect(user.avatar_url).to eq("https://avatars.githubusercontent.com/u/111?")
    expect(user.user_url).to eq("https://api.github.com/users/octocat")
    expect(user.html_url).to eq("https://github.com/octocat")
    expect(user.last_etag).to eq("\"user-etag\"")
    expect(JSON.parse(user.full_info)).to eq(JSON.parse(user_body(id: "111", login: "octocat")))

    push_event.reload
    expect(push_event.author).to eq(user)
    expect(push_event.user_unenrichable).to eq(false)
  end

  it "does not send If-None-Match when no User is known yet" do
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    stub_request(:get, user_url("111")).with { |request| !request.headers.key?("If-None-Match") }
      .to_return(status: 200, body: user_body, headers: { "ETag" => "\"etag\"" })

    Github::EnrichUser.call(push_event)

    expect(a_request(:get, user_url("111"))).to have_been_made
  end

  it "sends If-None-Match from an already-known User and links without creating a duplicate on a 304" do
    existing_user = User.create!(github_user_id: "111", login: "octocat", last_etag: "\"known-etag\"")
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    stub_request(:get, user_url("111")).with(headers: { "If-None-Match" => "\"known-etag\"" })
      .to_return(status: 304, body: "")

    expect { Github::EnrichUser.call(push_event) }.not_to change(User, :count)

    push_event.reload
    expect(push_event.author).to eq(existing_user)
  end

  it "updates an already-known User's fields when a 200 comes back with fresh data" do
    User.create!(github_user_id: "111", login: "octocat", last_etag: "\"stale-etag\"")
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    stub_request(:get, user_url("111"))
      .to_return(status: 200, body: user_body(id: "111", login: "octocat-renamed"), headers: { "ETag" => "\"fresh-etag\"" })

    expect { Github::EnrichUser.call(push_event) }.not_to change(User, :count)

    user = User.find_by(github_user_id: "111")
    expect(user.login).to eq("octocat-renamed")
    expect(user.last_etag).to eq("\"fresh-etag\"")

    push_event.reload
    expect(push_event.author).to eq(user)
  end

  it "links a second push event by an already-known author to the same User" do
    User.create!(github_user_id: "111", login: "octocat", last_etag: "\"known-etag\"")
    first = push_event_needing_enrichment(github_actor_id: "111")
    second = push_event_needing_enrichment(github_actor_id: "111")
    stub_request(:get, user_url("111")).to_return(status: 304, body: "")

    Github::EnrichUser.call(first)
    Github::EnrichUser.call(second)

    expect(User.count).to eq(1)
    expect(second.reload.author).to eq(first.reload.author)
  end

  it "marks user_unenrichable on a 4xx response and does not create a User" do
    push_event = push_event_needing_enrichment(github_actor_id: "999999")
    stub_request(:get, user_url("999999")).to_return(status: 404, body: "")

    expect { Github::EnrichUser.call(push_event) }.not_to change(User, :count)

    push_event.reload
    expect(push_event.user_unenrichable).to eq(true)
    expect(push_event.author_id).to be_nil
  end

  it "still records the Request for a 4xx response" do
    push_event = push_event_needing_enrichment(github_actor_id: "999999")
    stub_request(:get, user_url("999999")).to_return(status: 404, body: "")

    expect { Github::EnrichUser.call(push_event) }.to change(Request, :count).by(1)

    request = Request.last
    expect(request.purpose).to eq("enrich_user")
    expect(request.status_code).to eq(404)
  end

  it "logs an error and leaves the push event retryable when the HTTP request fails" do
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    stub_request(:get, user_url("111")).to_raise(Errno::ECONNREFUSED)

    logs = capture_logs do
      expect {
        expect { Github::EnrichUser.call(push_event) }.not_to change(User, :count)
      }.not_to change(Request, :count)
    end

    expect(logs).to match(/ERROR/)
    push_event.reload
    expect(push_event.author_id).to be_nil
    expect(push_event.user_unenrichable).to eq(false)
  end

  it "marks user_unenrichable without any HTTP call when github_actor_id is blank" do
    push_event = push_event_needing_enrichment(github_actor_id: nil)

    logs = capture_logs do
      Github::EnrichUser.call(push_event)
    end

    expect(logs).to match(/WARN/)
    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
    push_event.reload
    expect(push_event.user_unenrichable).to eq(true)
  end

  it "is a no-op when the push event is already enriched" do
    user = User.create!(github_user_id: "111", login: "octocat")
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    push_event.update!(author: user)

    Github::EnrichUser.call(push_event)

    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
  end

  it "is a no-op when the push event is already marked user_unenrichable" do
    push_event = push_event_needing_enrichment(github_actor_id: "111")
    push_event.update!(user_unenrichable: true)

    Github::EnrichUser.call(push_event)

    expect(a_request(:get, /api\.github\.com/)).not_to have_been_made
  end
end
