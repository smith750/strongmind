require "test_helper"

class GithubIngestJobTest < ActiveJob::TestCase
  EVENTS_URL = "https://api.github.com/events?per_page=100"

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

  test "wait_for returns BASE_WAIT for poll and enrichment decisions" do
    assert_equal GithubIngestJob::BASE_WAIT, GithubIngestJob.wait_for(result_for(:poll))
    assert_equal GithubIngestJob::BASE_WAIT, GithubIngestJob.wait_for(result_for(:enrich_repository))
    assert_equal GithubIngestJob::BASE_WAIT, GithubIngestJob.wait_for(result_for(:enrich_user))
  end

  test "wait_for returns IDLE_WAIT for an idle decision" do
    assert_equal GithubIngestJob::IDLE_WAIT, GithubIngestJob.wait_for(result_for(:idle))
  end

  test "wait_for computes the wait until ratelimit_reset for a rate_limited decision" do
    reset_at = 100.seconds.from_now.to_i
    wait = GithubIngestJob.wait_for(result_for(:rate_limited, ratelimit_reset: reset_at))
    assert_in_delta 100, wait.to_i, 2
  end

  test "wait_for floors at 1 second when ratelimit_reset is already in the past" do
    wait = GithubIngestJob.wait_for(result_for(:rate_limited, ratelimit_reset: 10.seconds.ago.to_i))
    assert_equal 1.second, wait
  end

  test "perform runs one Github::IngestCycle and self-reschedules" do
    stub_request(:get, EVENTS_URL).to_return(status: 200, body: "[]", headers: { "X-RateLimit-Remaining" => "50" })

    assert_enqueued_with(job: GithubIngestJob) do
      assert_difference "Request.count", 1 do
        GithubIngestJob.perform_now
      end
    end
  end

  test "chain_alive? is false when there is no unfinished GithubIngestJob row" do
    assert_not GithubIngestJob.chain_alive?
  end

  test "chain_alive? is true when a GithubIngestJob row is unfinished" do
    create_solid_queue_job
    assert GithubIngestJob.chain_alive?
  end

  test "chain_alive? ignores finished GithubIngestJob rows" do
    create_solid_queue_job(finished_at: Time.current)
    assert_not GithubIngestJob.chain_alive?
  end

  test "ensure_running enqueues a new job when no chain is alive" do
    assert_enqueued_with(job: GithubIngestJob) do
      GithubIngestJob.ensure_running
    end
  end

  test "ensure_running does not enqueue when a chain is already alive" do
    create_solid_queue_job

    assert_no_enqueued_jobs do
      GithubIngestJob.ensure_running
    end
  end
end
