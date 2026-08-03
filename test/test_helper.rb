ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

WebMock.disable_net_connect!

module ActiveSupport
  class TestCase
    # Parallel workers each need their own cloned test database; that clone hangs in
    # this environment (see docs/CLAUDE_IMPLEMENTATION.html Phase 4), and this suite
    # runs in well under a second single-process anyway, so keep it off rather than
    # risk the same hang in the "test" Docker Compose service.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
