module Github
  # The single entry point both "repeatable" (rake task, Phase 6) and "continuous"
  # (Solid Queue job, Phase 7) are built on - see docs/DESIGN.md "Continuous Ingestion".
  # Performs at most one HTTP request per call - a poll, a repository enrichment, or a
  # user enrichment - and returns. It has no knowledge of jobs, queues, or scheduling;
  # callers use the returned Result to decide how long to wait before calling again.
  class IngestCycle
    # Overridable via the RATE_LIMIT_SAFETY_FLOOR env var (see config/application.rb's
    # config.x.github.rate_limit_safety_floor) so it's easy to experiment with
    # different safety margins without a code change.
    RATE_LIMIT_SAFETY_FLOOR = Rails.application.config.x.github.rate_limit_safety_floor

    Result = Struct.new(:decision, :request, :ratelimit_reset, keyword_init: true)

    def self.call
      new.call
    end

    def call
      result = decide
      logger.info("[Github::IngestCycle] cycle complete, decision=#{result.decision}, request_id=#{result.request&.id.inspect}")
      result
    end

    private

    def decide
      latest_request = Request.order(created_at: :desc).first

      return poll unless latest_request
      return rate_limited(latest_request) if rate_limited?(latest_request)
      return poll if Time.current >= next_allowed_poll_at

      backlog_item = oldest_backlog_item
      return enrich(backlog_item) if backlog_item

      idle
    end

    def rate_limited?(latest_request)
      remaining = latest_request.ratelimit_remaining
      result = remaining.present? && remaining <= RATE_LIMIT_SAFETY_FLOOR
      logger.info("[Github::IngestCycle] rate_limited? remaining=#{remaining.inspect} => #{result}")
      result
    end

    def next_allowed_poll_at
      latest_poll = Request.where(purpose: :poll).order(created_at: :desc).first
      result = latest_poll ? latest_poll.created_at + latest_poll.poll_interval.seconds : Time.current
      logger.info("[Github::IngestCycle] next_allowed_poll_at=#{result}")
      result
    end

    def oldest_backlog_item
      result = PushEvent.where(repo_unenrichable: false, repository_id: nil)
        .or(PushEvent.where(user_unenrichable: false, author_id: nil))
        .order(:created_at)
        .first
      logger.info("[Github::IngestCycle] oldest_backlog_item=#{result&.id.inspect}")
      result
    end

    def poll
      request = PollPushEvents.call
      result = Result.new(decision: :poll, request: request, ratelimit_reset: nil)
      logger.info("[Github::IngestCycle] poll complete, request_id=#{request&.id.inspect}")
      result
    end

    def enrich(push_event)
      if push_event.repository_id.nil? && !push_event.repo_unenrichable?
        request = EnrichRepository.call(push_event)
        result = Result.new(decision: :enrich_repository, request: request, ratelimit_reset: nil)
      else
        request = EnrichUser.call(push_event)
        result = Result.new(decision: :enrich_user, request: request, ratelimit_reset: nil)
      end
      logger.info("[Github::IngestCycle] enrich complete, push_event_id=#{push_event.id}, decision=#{result.decision}, request_id=#{result.request&.id.inspect}")
      result
    end

    def rate_limited(latest_request)
      result = Result.new(decision: :rate_limited, request: nil, ratelimit_reset: latest_request.ratelimit_reset)
      logger.info("[Github::IngestCycle] rate_limited, ratelimit_reset=#{result.ratelimit_reset}")
      result
    end

    def idle
      result = Result.new(decision: :idle, request: nil, ratelimit_reset: nil)
      logger.info("[Github::IngestCycle] idle, nothing to do this cycle")
      result
    end

    def logger
      Rails.logger
    end
  end
end
