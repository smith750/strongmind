module Github
  # Resolves one PushEvent's repository, per docs/DESIGN.md "Fan Out": looks up whether we
  # already have a Repository for this push event's github_repository_id, makes one
  # conditional GET against GitHub's "get a repository by id" endpoint (using that
  # repository's last_etag if we have one), and either links the (possibly just-created
  # or just-refreshed) Repository or - on a 4xx - marks the push event permanently
  # repo_unenrichable so it drops out of the enrichment backlog.
  class EnrichRepository
    REPOSITORY_URL = "https://api.github.com/repositories".freeze

    def self.call(push_event)
      new(push_event).call
    end

    def initialize(push_event)
      @push_event = push_event
    end

    def call
      return if push_event.repository_id.present? || push_event.repo_unenrichable?

      github_repository_id = push_event.github_repository_id

      if github_repository_id.blank?
        logger.warn("[Github::EnrichRepository] push event #{push_event.id} has no github_repository_id, marking repo_unenrichable")
        push_event.update!(repo_unenrichable: true)
        return
      end

      existing_repository = Repository.find_by(github_repository_id: github_repository_id)

      result = ApiRequest.call(uri: uri(github_repository_id), purpose: :enrich_repo, etag: existing_repository&.last_etag)
      return unless result

      handle_response(result.response, github_repository_id, existing_repository)
      result.request
    end

    private

    attr_reader :push_event

    def uri(github_repository_id)
      URI("#{REPOSITORY_URL}/#{github_repository_id}")
    end

    def handle_response(response, github_repository_id, existing_repository)
      status = response.code.to_i

      case status
      when 304
        push_event.update!(repository: existing_repository) if existing_repository
      when 200
        repository = save_repository(github_repository_id, existing_repository, response)
        push_event.update!(repository: repository)
      when 400..499
        logger.warn("[Github::EnrichRepository] repository #{github_repository_id} unreachable (status #{status}), marking repo_unenrichable")
        push_event.update!(repo_unenrichable: true)
      end
    end

    def save_repository(github_repository_id, existing_repository, response)
      attributes = JSON.parse(response.body)

      repository = existing_repository || Repository.new(github_repository_id: github_repository_id)
      repository.assign_attributes(
        full_name: attributes["full_name"],
        html_url: attributes["html_url"],
        description: attributes["description"],
        url: attributes["url"],
        last_etag: response["ETag"],
        full_info: response.body
      )
      repository.save!
      repository
    rescue StandardError => e
      logger.error("[Github::EnrichRepository] error saving repository #{github_repository_id}: #{e.message}")
      existing_repository
    end

    def logger
      Rails.logger
    end
  end
end
