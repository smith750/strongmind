module Github
  # The single entry point both "repeatable" (rake task, Phase 6) and "continuous"
  # (Solid Queue job, Phase 7) are built on - see docs/DESIGN.md "Continuous Ingestion".
  # Performs at most one HTTP request per call - a poll, a repository enrichment, or a
  # user enrichment - and returns. It has no knowledge of jobs, queues, or scheduling;
  # callers use the returned Result to decide how long to wait before calling again.
  class IngestCycle
    RATE_LIMIT_SAFETY_FLOOR = 5

    Result = Struct.new(:decision, :request, :ratelimit_reset, keyword_init: true)

    def self.call
      new.call
    end

    def call
      latest_request = Request.order(created_at: :desc).first

      return poll unless latest_request
      return rate_limited(latest_request) if rate_limited?(latest_request)
      return poll if Time.current >= next_allowed_poll_at

      backlog_item = oldest_backlog_item
      return enrich(backlog_item) if backlog_item

      idle
    end

    private

    def rate_limited?(latest_request)
      remaining = latest_request.ratelimit_remaining
      remaining.present? && remaining <= RATE_LIMIT_SAFETY_FLOOR
    end

    def next_allowed_poll_at
      latest_poll = Request.where(purpose: :poll).order(created_at: :desc).first
      return Time.current unless latest_poll

      latest_poll.created_at + latest_poll.poll_interval.seconds
    end

    def oldest_backlog_item
      PushEvent.where(repo_unenrichable: false, repository_id: nil)
        .or(PushEvent.where(user_unenrichable: false, author_id: nil))
        .order(:created_at)
        .first
    end

    def poll
      request = PollPushEvents.call
      Result.new(decision: :poll, request: request, ratelimit_reset: nil)
    end

    def enrich(push_event)
      if push_event.repository_id.nil? && !push_event.repo_unenrichable?
        request = EnrichRepository.call(push_event)
        Result.new(decision: :enrich_repository, request: request, ratelimit_reset: nil)
      else
        request = EnrichUser.call(push_event)
        Result.new(decision: :enrich_user, request: request, ratelimit_reset: nil)
      end
    end

    def rate_limited(latest_request)
      Result.new(decision: :rate_limited, request: nil, ratelimit_reset: latest_request.ratelimit_reset)
    end

    def idle
      Result.new(decision: :idle, request: nil, ratelimit_reset: nil)
    end
  end
end
