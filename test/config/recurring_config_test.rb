require "test_helper"
require "yaml"

class RecurringConfigTest < ActiveSupport::TestCase
  def recurring_config
    YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
  end

  test "the github ingest heartbeat is wired up for development and production" do
    %w[development production].each do |env|
      entry = recurring_config.fetch(env).fetch("github_ingest_heartbeat")
      assert_equal "GithubIngestJob.ensure_running", entry["command"]
      assert_equal "every hour", entry["schedule"]
    end
  end
end
