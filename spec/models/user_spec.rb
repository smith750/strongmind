require "rails_helper"

RSpec.describe User, type: :model do
  def valid_attributes
    { github_user_id: "6789", login: "octocat" }
  end

  it "is valid with a github_user_id" do
    expect(User.new(valid_attributes)).to be_valid
  end

  it "is invalid without a github_user_id" do
    user = User.new(valid_attributes.except(:github_user_id))
    expect(user).not_to be_valid
    expect(user.errors[:github_user_id]).to include("can't be blank")
  end

  it "is invalid with a duplicate github_user_id" do
    User.create!(valid_attributes)
    duplicate = User.new(valid_attributes)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_user_id]).to include("has already been taken")
  end

  it "enforces uniqueness of github_user_id at the database level" do
    User.create!(valid_attributes)
    expect {
      User.insert!(valid_attributes.merge(created_at: Time.current, updated_at: Time.current))
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "has many push events as author" do
    user = User.create!(valid_attributes)
    push_event = PushEvent.create!(github_event_id: "evt-1", author: user)
    expect(user.push_events).to eq([ push_event ])
  end
end
