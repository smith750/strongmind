require "test_helper"

class RepositoryTest < ActiveSupport::TestCase
  def valid_attributes
    { github_repository_id: "12345", full_name: "octocat/hello-world" }
  end

  test "valid with a github_repository_id" do
    assert Repository.new(valid_attributes).valid?
  end

  test "invalid without a github_repository_id" do
    repository = Repository.new(valid_attributes.except(:github_repository_id))
    assert_not repository.valid?
    assert_includes repository.errors[:github_repository_id], "can't be blank"
  end

  test "invalid with a duplicate github_repository_id" do
    Repository.create!(valid_attributes)
    duplicate = Repository.new(valid_attributes)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:github_repository_id], "has already been taken"
  end

  test "enforces uniqueness of github_repository_id at the database level" do
    Repository.create!(valid_attributes)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Repository.insert!(valid_attributes.merge(created_at: Time.current, updated_at: Time.current))
    end
  end

  test "has many push events" do
    repository = Repository.create!(valid_attributes)
    push_event = PushEvent.create!(github_event_id: "evt-1", repository: repository)
    assert_equal [ push_event ], repository.push_events
  end
end
