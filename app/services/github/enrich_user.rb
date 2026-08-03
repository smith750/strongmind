module Github
  # Resolves one PushEvent's author, per docs/DESIGN.md "Fan Out": looks up whether we
  # already have a User for this push event's github_actor_id, makes one conditional GET
  # against GitHub's "get a user by id" endpoint (using that User's last_etag if we have
  # one), and either links an existing/freshly-created User or - on a 4xx - marks the
  # push event permanently user_unenrichable so it drops out of the enrichment backlog.
  class EnrichUser
    USER_URL = "https://api.github.com/user".freeze

    def self.call(push_event)
      new(push_event).call
    end

    def initialize(push_event)
      @push_event = push_event
    end

    def call
      return if push_event.author_id.present? || push_event.user_unenrichable?

      github_actor_id = push_event.github_actor_id

      if github_actor_id.blank?
        logger.warn("[Github::EnrichUser] push event #{push_event.id} has no github_actor_id, marking user_unenrichable")
        push_event.update!(user_unenrichable: true)
        return
      end

      existing_user = User.find_by(github_user_id: github_actor_id)

      result = ApiRequest.call(uri: uri(github_actor_id), purpose: :enrich_user, etag: existing_user&.last_etag)
      return unless result

      handle_response(result.response, github_actor_id, existing_user)
    end

    private

    attr_reader :push_event

    def uri(github_actor_id)
      URI("#{USER_URL}/#{github_actor_id}")
    end

    def handle_response(response, github_actor_id, existing_user)
      status = response.code.to_i

      case status
      when 304
        push_event.update!(author: existing_user) if existing_user
      when 200
        user = save_user(github_actor_id, existing_user, response)
        push_event.update!(author: user)
      when 400..499
        logger.warn("[Github::EnrichUser] user #{github_actor_id} unreachable (status #{status}), marking user_unenrichable")
        push_event.update!(user_unenrichable: true)
      end
    end

    def save_user(github_actor_id, existing_user, response)
      attributes = JSON.parse(response.body)

      user = existing_user || User.new(github_user_id: github_actor_id)
      user.assign_attributes(
        login: attributes["login"],
        avatar_url: attributes["avatar_url"],
        user_url: attributes["url"],
        html_url: attributes["html_url"],
        last_etag: response["ETag"],
        full_info: response.body
      )
      user.save!
      user
    rescue StandardError => e
      logger.error("[Github::EnrichUser] error saving user #{github_actor_id}: #{e.message}")
      existing_user
    end

    def logger
      Rails.logger
    end
  end
end
