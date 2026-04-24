class DarkFactoryJob < ApplicationJob
  class NoChangesMade < StandardError; end

  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    fr.update!(status: "doing", branch_name: fr.branch)

    worktree = WorktreeManager.new(repo_root: Rails.root.to_s, branch: fr.branch)
    worktree.setup!

    begin
      AgentRunner.new(feature_request: fr, worktree_path: worktree.path).run!
      ensure_agent_made_commits!(worktree.path)
      pr_url = PrCreator.new(feature_request: fr, worktree_path: worktree.path).create!
      fr.update!(status: "to_review", pr_url: pr_url)
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "budget_exceeded: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue NoChangesMade => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue PrCreator::Error => e
      fr.update!(status: "failed", failure_reason: "push_failed: #{e.message}")
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "job_crashed: #{e.class}: #{e.message}")
    raise
  end

  private

  def ensure_agent_made_commits!(worktree_path)
    out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-list", "--count", "main..HEAD")
    count = status.success? ? out.strip.to_i : 0
    raise NoChangesMade, "no_changes_made: agent finished without committing anything" if count.zero?
  end
end
