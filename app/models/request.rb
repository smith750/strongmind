class Request < ApplicationRecord
  enum :purpose, { poll: 0, enrich_repo: 1, enrich_user: 2 }

  validates :purpose, presence: true
end
