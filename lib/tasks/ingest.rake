namespace :ingest do
  desc "Run one Github::IngestCycle and exit - the 'repeatable' entry point (see docs/DESIGN.md Continuous Ingestion)"
  task once: :environment do
    result = Github::IngestCycle.call
    Rails.logger.info("[ingest:once] cycle complete, decision=#{result.decision}")
  end
end
