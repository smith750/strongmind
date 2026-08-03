require "rails_helper"
require "yaml"

RSpec.describe "config/recurring.yml" do
  def recurring_config
    YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
  end

  it "wires up the github ingest heartbeat for development and production" do
    %w[development production].each do |env|
      entry = recurring_config.fetch(env).fetch("github_ingest_heartbeat")
      expect(entry["command"]).to eq("GithubIngestJob.ensure_running")
      expect(entry["schedule"]).to eq("every hour")
    end
  end
end
