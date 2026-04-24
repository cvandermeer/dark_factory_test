class DarkFactoryJob < ApplicationJob
  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)

    Rails.logger.info("[DarkFactory] starting FR##{fr.id}: #{fr.title}")
    fr.update!(status: "doing")

    # --- placeholder for real agent run (Task 12) ---
    sleep 3
    fr.agent_events.create!(
      kind: "system",
      payload: { message: "Fake run — agent not implemented yet" },
      sequence: 0
    )
    sleep 2
    # --- end placeholder ---

    fr.update!(
      status: "to_review",
      branch_name: fr.branch,
      pr_url: "https://github.com/cvandermeer/dark_factory_test/pull/fake"
    )
    Rails.logger.info("[DarkFactory] finished FR##{fr.id}")
  rescue => e
    fr&.update!(status: "failed", failure_reason: "job_crashed: #{e.class}: #{e.message}")
    raise
  end
end
