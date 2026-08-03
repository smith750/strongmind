require "test_helper"

class UserTest < ActiveSupport::TestCase
  def valid_attributes
    { github_user_id: "6789", login: "octocat" }
  end

  test "valid with a github_user_id" do
    assert User.new(valid_attributes).valid?
  end

  test "invalid without a github_user_id" do
    user = User.new(valid_attributes.except(:github_user_id))
    assert_not user.valid?
    assert_includes user.errors[:github_user_id], "can't be blank"
  end

  test "invalid with a duplicate github_user_id" do
    User.create!(valid_attributes)
    duplicate = User.new(valid_attributes)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:github_user_id], "has already been taken"
  end

  test "enforces uniqueness of github_user_id at the database level" do
    User.create!(valid_attributes)
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert!(valid_attributes.merge(created_at: Time.current, updated_at: Time.current))
    end
  end

  test "has many push events as author" do
    user = User.create!(valid_attributes)
    push_event = PushEvent.create!(github_event_id: "evt-1", author: user)
    assert_equal [ push_event ], user.push_events
  end
end
