class User < ApplicationRecord
  has_many :push_events, foreign_key: :author_id, inverse_of: :author

  validates :github_user_id, presence: true, uniqueness: true
end
