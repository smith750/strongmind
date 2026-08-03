class Repository < ApplicationRecord
  has_many :push_events

  validates :github_repository_id, presence: true, uniqueness: true
end
