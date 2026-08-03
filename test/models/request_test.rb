require "test_helper"

class RequestTest < ActiveSupport::TestCase
  def valid_attributes
    { url: "https://api.github.com/events", purpose: :poll }
  end

  test "valid with a purpose" do
    assert Request.new(valid_attributes).valid?
  end

  test "invalid without a purpose" do
    request = Request.new(valid_attributes.except(:purpose))
    assert_not request.valid?
    assert_includes request.errors[:purpose], "can't be blank"
  end

  test "exposes purpose as an enum of poll, enrich_repo, enrich_user" do
    assert_equal({ "poll" => 0, "enrich_repo" => 1, "enrich_user" => 2 }, Request.purposes)
  end

  test "poll_interval defaults to 0" do
    request = Request.create!(valid_attributes)
    assert_equal 0, request.poll_interval
  end

  test "raises on an invalid purpose value" do
    assert_raises(ArgumentError) { Request.new(purpose: :unknown) }
  end

  test "can record rate limit and etag details from a response" do
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

    assert request.persisted?
    assert_equal 90, request.poll_interval
  end
end
