require "test_helper"

class PushEventTest < ActiveSupport::TestCase
  def valid_attributes
    { github_event_id: "evt-1", github_push_id: "push-1", ref: "refs/heads/main" }
  end

  test "valid with a github_event_id" do
    assert PushEvent.new(valid_attributes).valid?
  end

  test "invalid without a github_event_id" do
    push_event = PushEvent.new(valid_attributes.except(:github_event_id))
    assert_not push_event.valid?
    assert_includes push_event.errors[:github_event_id], "can't be blank"
  end

  test "invalid with a duplicate github_event_id" do
    PushEvent.create!(valid_attributes)
    duplicate = PushEvent.new(valid_attributes)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:github_event_id], "has already been taken"
  end

  test "enforces uniqueness of github_event_id at the database level" do
    PushEvent.create!(valid_attributes)
    assert_raises(ActiveRecord::RecordNotUnique) do
      PushEvent.insert!(valid_attributes.merge(created_at: Time.current, updated_at: Time.current))
    end
  end

  test "repository and author are optional, since they are filled in later by enrichment" do
    push_event = PushEvent.create!(valid_attributes)
    assert_nil push_event.repository_id
    assert_nil push_event.author_id
  end

  test "repo_unenrichable and user_unenrichable default to false" do
    push_event = PushEvent.create!(valid_attributes)
    assert_equal false, push_event.repo_unenrichable
    assert_equal false, push_event.user_unenrichable
  end

  test "belongs to a repository" do
    repository = Repository.create!(github_repository_id: "12345")
    push_event = PushEvent.create!(valid_attributes.merge(repository: repository))
    assert_equal repository, push_event.repository
  end

  test "belongs to an author, which is a User" do
    user = User.create!(github_user_id: "6789")
    push_event = PushEvent.create!(valid_attributes.merge(author: user))
    assert_equal user, push_event.author
  end
end
