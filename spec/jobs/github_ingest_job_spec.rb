require "rails_helper"

RSpec.describe GithubIngestJob, type: :job do
  def events_url
    "https://api.github.com/events?per_page=100"
  end

  def result_for(decision, ratelimit_reset: nil)
    Github::IngestCycle::Result.new(decision: decision, request: nil, ratelimit_reset: ratelimit_reset)
  end

  def create_solid_queue_job(finished_at: nil)
    SolidQueue::Job.create!(
      queue_name: "default",
      class_name: "GithubIngestJob",
      arguments: [],
      active_job_id: SecureRandom.uuid,
      scheduled_at: Time.current,
      finished_at: finished_at
    )
  end

  it "returns BASE_WAIT for poll and enrichment decisions" do
    expect(GithubIngestJob.wait_for(result_for(:poll))).to eq(GithubIngestJob::BASE_WAIT)
    expect(GithubIngestJob.wait_for(result_for(:enrich_repository))).to eq(GithubIngestJob::BASE_WAIT)
    expect(GithubIngestJob.wait_for(result_for(:enrich_user))).to eq(GithubIngestJob::BASE_WAIT)
  end

  it "returns IDLE_WAIT for an idle decision" do
    expect(GithubIngestJob.wait_for(result_for(:idle))).to eq(GithubIngestJob::IDLE_WAIT)
  end

  it "computes the wait until ratelimit_reset for a rate_limited decision" do
    reset_at = 100.seconds.from_now.to_i
    wait = GithubIngestJob.wait_for(result_for(:rate_limited, ratelimit_reset: reset_at))
    expect(wait.to_i).to be_within(2).of(100)
  end

  it "floors at 1 second when ratelimit_reset is already in the past" do
    wait = GithubIngestJob.wait_for(result_for(:rate_limited, ratelimit_reset: 10.seconds.ago.to_i))
    expect(wait).to eq(1.second)
  end

  it "runs one Github::IngestCycle and self-reschedules" do
    stub_request(:get, events_url).to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" })

    expect {
      expect { GithubIngestJob.perform_now }.to change(Request, :count).by(1)
    }.to have_enqueued_job(GithubIngestJob)
  end

  it "reports chain_alive? as false when there is no unfinished GithubIngestJob row" do
    expect(GithubIngestJob).not_to be_chain_alive
  end

  it "reports chain_alive? as true when a GithubIngestJob row is unfinished" do
    create_solid_queue_job
    expect(GithubIngestJob).to be_chain_alive
  end

  it "has chain_alive? ignore finished GithubIngestJob rows" do
    create_solid_queue_job(finished_at: Time.current)
    expect(GithubIngestJob).not_to be_chain_alive
  end

  it "enqueues a new job via ensure_running when no chain is alive" do
    expect { GithubIngestJob.ensure_running }.to have_enqueued_job(GithubIngestJob)
  end

  it "does not enqueue via ensure_running when a chain is already alive" do
    create_solid_queue_job

    expect { GithubIngestJob.ensure_running }.not_to have_enqueued_job
  end
end
