require "rails_helper"

RSpec.describe Repository, type: :model do
  def valid_attributes
    { github_repository_id: "12345", full_name: "octocat/hello-world" }
  end

  it "is valid with a github_repository_id" do
    expect(Repository.new(valid_attributes)).to be_valid
  end

  it "is invalid without a github_repository_id" do
    repository = Repository.new(valid_attributes.except(:github_repository_id))
    expect(repository).not_to be_valid
    expect(repository.errors[:github_repository_id]).to include("can't be blank")
  end

  it "is invalid with a duplicate github_repository_id" do
    Repository.create!(valid_attributes)
    duplicate = Repository.new(valid_attributes)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:github_repository_id]).to include("has already been taken")
  end

  it "enforces uniqueness of github_repository_id at the database level" do
    Repository.create!(valid_attributes)
    expect {
      Repository.insert!(valid_attributes.merge(created_at: Time.current, updated_at: Time.current))
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "has many push events" do
    repository = Repository.create!(valid_attributes)
    push_event = PushEvent.create!(github_event_id: "evt-1", repository: repository)
    expect(repository.push_events).to eq([ push_event ])
  end
end
