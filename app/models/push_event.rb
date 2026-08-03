class PushEvent < ApplicationRecord
  belongs_to :repository, optional: true
  belongs_to :author, class_name: "User", inverse_of: :push_events, optional: true

  validates :github_event_id, presence: true, uniqueness: true
end
