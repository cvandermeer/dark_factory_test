class AddressFeedbackJob < ApplicationJob
  class NoChangesMade < StandardError; end

  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    return unless fr.status == "review_feedback"

    fr.update!(status: "doing")

    worktree = WorktreeManager.new(
      repo_root: Rails.root.to_s,
      branch: fr.branch_name,
      mode: :checkout_existing
    )
    worktree.setup!

    begin
      # Make sure the worktree HEAD is on a branch (not detached) so the agent's commits
      # land somewhere we can push.
      Open3.capture3("git", "-C", worktree.path, "switch", "-C", fr.branch_name)

      fetcher = FeedbackFetcher.new(pr_url: fr.pr_url)
      diff = fetcher.fetch_diff(worktree.path)
      feedback = fetcher.fetch_feedback

      AgentRunner.new(
        feature_request: fr,
        worktree_path: worktree.path,
        mode: :address,
        stdin_payload: { title: fr.title, body: fr.body, diff: diff, feedback: feedback }
      ).run!

      ensure_agent_made_commits!(worktree.path, fr.branch_name)
      push_branch!(worktree.path, fr.branch_name)
      fr.update!(status: "to_review", feedback_addressed: true)
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "address_timeout: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: "address_failed: #{e.message}")
    rescue NoChangesMade => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue PushFailed => e
      fr.update!(status: "failed", failure_reason: "address_push_failed: #{e.message}")
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "address_crashed: #{e.class}: #{e.message}")
    raise
  end

  class PushFailed < StandardError; end

  private

  def ensure_agent_made_commits!(worktree_path, branch)
    out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-list", "--count", "origin/#{branch}..HEAD")
    count = status.success? ? out.strip.to_i : 0
    if count.zero?
      raise NoChangesMade, "address_no_changes: agent finished without committing anything"
    end
  end

  def push_branch!(worktree_path, branch)
    _out, err, status = Open3.capture3(
      "git", "-C", worktree_path, "push", "origin", "HEAD:#{branch}"
    )
    raise PushFailed, err.to_s unless status.success?
  end
end
