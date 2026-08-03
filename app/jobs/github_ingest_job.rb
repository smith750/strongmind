# The "continuous" entry point from docs/DESIGN.md "Continuous Ingestion": wraps
# Github::IngestCycle and self-reschedules with perform_later(wait: ...), so as long as
# bin/jobs is running the chain keeps going unattended. Its "escape" is Solid Queue's own
# graceful shutdown on SIGTERM/SIGINT (the in-flight cycle finishes, no new one is
# claimed) - nothing to implement here for that. Its "sleep" is the wait computed below.
class GithubIngestJob < ApplicationJob
  queue_as :default

  # A short pause between cycles that did real work (poll or enrich), so the chain keeps
  # draining the backlog/polling without a tight loop hammering the queue and database.
  BASE_WAIT = 1.second
  # A longer pause when there's nothing to do at all.
  IDLE_WAIT = 30.seconds

  class << self
    # config/recurring.yml's heartbeat calls this, not perform_later directly, so a
    # healthy self-rescheduling chain doesn't get a second one started alongside it -
    # only re-enqueues if the chain has actually died.
    def ensure_running
      return if chain_alive?

      perform_later
    end

    def chain_alive?
      SolidQueue::Job.where(class_name: name, finished_at: nil).exists?
    end

    def wait_for(result)
      case result.decision
      when :rate_limited
        [ result.ratelimit_reset - Time.current.to_i, 1 ].max.seconds
      when :idle
        IDLE_WAIT
      else
        BASE_WAIT
      end
    end
  end

  def perform
    result = Github::IngestCycle.call
    self.class.set(wait: self.class.wait_for(result)).perform_later
  end
end
