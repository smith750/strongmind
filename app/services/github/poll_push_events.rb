module Github
  # Pulls one page of GitHub's public /events feed, saves a Request record describing
  # the response (for rate-limit/etag tracking - see docs/DESIGN.md "Rate limits"), and
  # saves a PushEvent for every entry of type "PushEvent". All other event types are ignored.
  class PollPushEvents
    EVENTS_URL = "https://api.github.com/events".freeze

    def self.call
      new.call
    end

    def call
      result = ApiRequest.call(uri: uri, purpose: :poll, etag: last_etag)
      return unless result

      process_events(result.response.body) if result.response.code.to_i == 200

      result.request
    end

    private

    def uri
      @uri ||= URI("#{EVENTS_URL}?per_page=100")
    end

    def last_etag
      Request.where(purpose: :poll).order(created_at: :desc).first&.etag
    end

    def process_events(body)
      events = JSON.parse(body)
      events.each { |event| save_push_event(event) if event["type"] == "PushEvent" }
    rescue JSON::ParserError => e
      logger.error("[Github::PollPushEvents] failed to parse response body: #{e.message}")
    end

    def save_push_event(event)
      github_event_id = event["id"]

      if github_event_id.blank?
        logger.warn("[Github::PollPushEvents] could not parse push event, missing id: #{event.inspect}")
        return
      end

      logger.info("[Github::PollPushEvents] parsed push event #{github_event_id}")

      payload = event["payload"] || {}
      repo = event["repo"] || {}
      actor = event["actor"] || {}

      PushEvent.find_or_create_by!(github_event_id: github_event_id) do |pe|
        pe.github_push_id = payload["push_id"]&.to_s
        pe.github_repository_id = repo["id"]&.to_s
        pe.ref = payload["ref"]
        pe.head = payload["head"]
        pe.before = payload["before"]
        pe.github_actor_id = actor["id"]&.to_s
        pe.full_info = event.to_json
      end

      logger.info("[Github::PollPushEvents] saved push event #{github_event_id}")
    rescue StandardError => e
      logger.error("[Github::PollPushEvents] error saving push event #{github_event_id}: #{e.message}")
    end

    def logger
      Rails.logger
    end
  end
end
