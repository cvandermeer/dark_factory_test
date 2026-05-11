class IdeaGenerationJob < ApplicationJob
  queue_as :default

  def perform
    return unless FactorySetting.automatic?
    return if active_work_exists?

    proposal = IdeaAgentRunner.new(
      vision: vision,
      recent_requests: recent_requests
    ).run!

    body = [
      proposal.body,
      "",
      "Automatic rationale:",
      proposal.rationale.presence || "Generated from project vision."
    ].join("\n")

    FeatureRequest.create!(
      title: proposal.title,
      body: body,
      source: "automatic"
    )
  rescue IdeaAgentRunner::Error => e
    Rails.logger.warn("[IdeaGenerationJob] #{e.class}: #{e.message}")
  end

  private

  def active_work_exists?
    FeatureRequest.where(status: %w[todo doing reviewing addressing_feedback landing]).exists?
  end

  def vision
    ProjectVision.read
  end

  def recent_requests
    FeatureRequest.order(created_at: :desc).limit(10).map do |fr|
      "- [#{fr.status}] #{fr.title}: #{fr.body.to_s.truncate(240)}"
    end.join("\n")
  end
end
