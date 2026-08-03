require "rails_helper"

RSpec.describe PushEvent, type: :model do
  def valid_attributes
    { github_event_id: "evt-1", github_push_id: "push-1", ref: "refs/heads/main" }
  end

  it "is valid with a github_event_id" do
    expect(PushEvent.new(valid_attributes)).to be_valid
  end

  it "is invalid without a github_event_id" do
    push_event = PushEvent.new(valid_attributes.except(:github_event_id))
    expect(push_event).not_to be_valid
    expect(push_event.errors[:github_event_id]).to include("can't be blank")
  end

  it "is invalid with a duplicate github_event_id" do
    PushEvent.create!(valid_attributes)
    duplicate = PushEvent.new(valid_attributes)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_event_id]).to include("has already been taken")
  end

  it "enforces uniqueness of github_event_id at the database level" do
    PushEvent.create!(valid_attributes)
    expect {
      PushEvent.insert!(valid_attributes.merge(created_at: Time.current, updated_at: Time.current))
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "leaves repository and author optional, since they are filled in later by enrichment" do
    push_event = PushEvent.create!(valid_attributes)
    expect(push_event.repository_id).to be_nil
    expect(push_event.author_id).to be_nil
  end

  it "defaults repo_unenrichable and user_unenrichable to false" do
    push_event = PushEvent.create!(valid_attributes)
    expect(push_event.repo_unenrichable).to eq(false)
    expect(push_event.user_unenrichable).to eq(false)
  end

  it "belongs to a repository" do
    repository = Repository.create!(github_repository_id: "12345")
    push_event = PushEvent.create!(valid_attributes.merge(repository: repository))
    expect(push_event.repository).to eq(repository)
  end

  it "belongs to an author, which is a User" do
    user = User.create!(github_user_id: "6789")
    push_event = PushEvent.create!(valid_attributes.merge(author: user))
    expect(push_event.author).to eq(user)
  end
end
