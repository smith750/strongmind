require "rails_helper"

RSpec.describe Request, type: :model do
  def valid_attributes
    { url: "https://api.github.com/events", purpose: :poll }
  end

  it "is valid with a purpose" do
    expect(Request.new(valid_attributes)).to be_valid
  end

  it "is invalid without a purpose" do
    request = Request.new(valid_attributes.except(:purpose))
    expect(request).not_to be_valid
    expect(request.errors[:purpose]).to include("can't be blank")
  end

  it "exposes purpose as an enum of poll, enrich_repo, enrich_user" do
    expect(Request.purposes).to eq({ "poll" => 0, "enrich_repo" => 1, "enrich_user" => 2 })
  end

  it "defaults poll_interval to 0" do
    request = Request.create!(valid_attributes)
    expect(request.poll_interval).to eq(0)
  end

  it "raises on an invalid purpose value" do
    expect { Request.new(purpose: :unknown) }.to raise_error(ArgumentError)
  end

  it "can record rate limit and etag details from a response" do
    request = Request.create!(
      url: "https://api.github.com/events",
      purpose: :poll,
      etag: "W/\"abc123\"",
      retry_after: 60,
      ratelimit_remaining: 59,
      ratelimit_reset: 1_700_000_000,
      poll_interval: 90,
      status_code: 200
    )

    expect(request).to be_persisted
    expect(request.poll_interval).to eq(90)
  end
end
