class ReviewAgentJob < ApplicationJob
  class ReviewerSilent < StandardError; end

  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    return unless fr.pr_url.present?

    worktree = WorktreeManager.new(
      repo_root: Rails.root.to_s,
      branch: fr.branch_name,
      mode: :checkout_existing
    )
    worktree.setup!

    begin
      AgentRunner.new(
        feature_request: fr,
        worktree_path: worktree.path,
        mode: :reviewer,
        stdin_payload: { title: fr.title, body: fr.body, pr_url: fr.pr_url }
      ).run!

      ensure_review_was_posted!(fr)
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "reviewer_timeout: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: "reviewer_failed: #{e.message}")
    rescue ReviewerSilent => e
      fr.update!(status: "failed", failure_reason: e.message)
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "reviewer_crashed: #{e.class}: #{e.message}")
    raise
  end

  private

  def ensure_review_was_posted!(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "reviews"
    )
    return unless status.success?
    reviews = JSON.parse(out).fetch("reviews", [])
    if reviews.empty?
      raise ReviewerSilent, "reviewer_silent: agent completed without posting a review"
    end
  end
end
