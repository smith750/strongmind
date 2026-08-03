require "net/http"

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
      response = fetch_events
      return unless response

      request = persist_request(response)
      return unless request

      process_events(response.body) if response.code.to_i == 200

      request
    end

    private

    def uri
      @uri ||= URI("#{EVENTS_URL}?per_page=100")
    end

    def fetch_events
      logger.debug("[Github::PollPushEvents] fetching #{uri}")

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["If-None-Match"] = last_etag if last_etag.present?

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    rescue StandardError => e
      logger.error("[Github::PollPushEvents] request failed: #{e.class}: #{e.message}")
      nil
    end

    def last_etag
      Request.where(purpose: :poll).order(created_at: :desc).first&.etag
    end

    def persist_request(response)
      status = response.code.to_i

      if status >= 500
        logger.error("[Github::PollPushEvents] request failed with status #{status}")
        return nil
      end

      logger.info("[Github::PollPushEvents] request successful, status=#{status}")

      Request.create!(
        url: uri.to_s,
        etag: response["ETag"],
        retry_after: response["Retry-After"],
        ratelimit_remaining: response["X-RateLimit-Remaining"],
        ratelimit_reset: response["X-RateLimit-Reset"],
        poll_interval: response["X-Poll-Interval"] || 0,
        purpose: :poll,
        status_code: status
      )
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
