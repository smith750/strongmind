require "net/http"

module Github
  # Performs one conditional GET against a GitHub API URL and records a Request row
  # describing the response - the single-HTTP-request-per-call building block that
  # docs/DESIGN.md's "Continuous Ingestion" section describes IngestCycle as composing
  # (poll, enrich a repository, or enrich a user).
  #
  # Returns a Result (with #response and #request) on any real response from GitHub,
  # or nil if the request itself failed (network error, or a 5xx - see docs/DESIGN.md's
  # note that these don't get a persisted Request row and are simply retried next cycle).
  class ApiRequest
    Result = Struct.new(:response, :request, keyword_init: true)

    # Maps Request#purpose to a standardized object-type name for the "FETCH <type>"
    # log line - grep-able so the ratio of events/repos/users fetched is easy to see,
    # to help tune the RATE_LIMIT_SAFETY_FLOOR env var (see Github::IngestCycle).
    OBJECT_TYPES = { poll: "events", enrich_repo: "repos", enrich_user: "users" }.freeze

    def self.call(uri:, purpose:, etag: nil)
      new(uri: uri, purpose: purpose, etag: etag).call
    end

    def initialize(uri:, purpose:, etag: nil)
      @uri = uri
      @purpose = purpose
      @etag = etag
    end

    def call
      response = fetch
      return nil unless response

      request = persist_request(response)
      return nil unless request

      Result.new(response: response, request: request)
    end

    private

    attr_reader :uri, :purpose, :etag

    def fetch
      logger.debug("[Github::ApiRequest] fetching #{uri} (purpose=#{purpose})")
      logger.info("[Github::ApiRequest] FETCH #{object_type}")

      http_request = Net::HTTP::Get.new(uri)
      http_request["Accept"] = "application/vnd.github+json"
      http_request["If-None-Match"] = etag if etag.present?

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(http_request) }
    rescue StandardError => e
      logger.error("[Github::ApiRequest] request failed: #{e.class}: #{e.message}")
      nil
    end

    def persist_request(response)
      status = response.code.to_i

      if status >= 500
        logger.error("[Github::ApiRequest] request failed with status #{status}")
        return nil
      end

      logger.info("[Github::ApiRequest] request successful, status=#{status}")

      Request.create!(
        url: uri.to_s,
        etag: response["ETag"],
        retry_after: response["Retry-After"],
        ratelimit_remaining: response["X-RateLimit-Remaining"],
        ratelimit_reset: response["X-RateLimit-Reset"],
        poll_interval: response["X-Poll-Interval"] || 0,
        purpose: purpose,
        status_code: status
      )
    end

    def object_type
      OBJECT_TYPES.fetch(purpose)
    end

    def logger
      Rails.logger
    end
  end
end
