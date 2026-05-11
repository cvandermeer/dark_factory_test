class DarkFactoryJob < ApplicationJob
  class NoChangesMade < StandardError; end
  class ReviewRejected < StandardError; end
  class StopRequested < StandardError; end

  queue_as :default

  def perform(feature_request_id)
    fr = FeatureRequest.find(feature_request_id)
    fr.update!(status: "doing", branch_name: fr.branch)

    worktree = WorktreeManager.new(repo_root: Rails.root.to_s, branch: fr.branch)
    worktree.setup!

    begin
      check_stop!(fr)
      AgentRunner.new(feature_request: fr, worktree_path: worktree.path).run!
      check_stop!(fr)
      ensure_agent_made_commits!(worktree.path)
      review = review!(fr, worktree.path)
      check_stop!(fr)

      if review.verdict == "changes_requested"
        fr.update!(status: "addressing_feedback", feedback_addressed: true)
        address_feedback!(fr, worktree.path, review.body)
        check_stop!(fr)
        review = review!(fr, worktree.path)
        if review.verdict == "changes_requested"
          raise ReviewRejected, "review_changes_unresolved: #{review.body}"
        end
      end

      check_stop!(fr)
      fr.update!(status: "landing")
      worktree.teardown!
      check_stop!(fr)

      landed_sha = MainlineLandinger.new(
        repo_root: Rails.root.to_s,
        branch: fr.branch,
        title: fr.title,
        stop_requested: -> { fr.reload.stop_requested? }
      ).land!
      fr.update!(status: "done", landed_commit_sha: landed_sha)
      IdeaGenerationJob.perform_later if FactorySetting.automatic?
    rescue StopRequested, AgentRunner::Stopped, MainlineLandinger::Stopped
      fr.update!(status: "stopped", failure_reason: "stopped_by_user")
    rescue AgentRunner::Timeout
      fr.update!(status: "failed", failure_reason: "budget_exceeded: 15 min")
    rescue AgentRunner::AgentFailed => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue NoChangesMade => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue ReviewVerdictParser::Error => e
      fr.update!(status: "failed", failure_reason: "review_parse_failed: #{e.message}")
    rescue ReviewRejected => e
      fr.update!(status: "failed", failure_reason: e.message)
    rescue MainlineLandinger::Error => e
      fr.update!(status: "failed", failure_reason: e.message)
    ensure
      worktree.teardown!
    end
  rescue => e
    fr&.update!(status: "failed", failure_reason: "job_crashed: #{e.class}: #{e.message}")
    raise
  end

  private

  def check_stop!(fr)
    raise StopRequested, "stopped_by_user" if fr.reload.stop_requested?
  end

  def ensure_agent_made_commits!(worktree_path)
    out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-list", "--count", "main..HEAD")
    count = status.success? ? out.strip.to_i : 0
    raise NoChangesMade, "no_changes_made: agent finished without committing anything" if count.zero?
  end

  def review!(fr, worktree_path)
    check_stop!(fr)
    fr.update!(status: "reviewing")
    first_review_sequence = fr.agent_events.maximum(:sequence).to_i + 1
    AgentRunner.new(
      feature_request: fr,
      worktree_path: worktree_path,
      mode: :reviewer,
      stdin_payload: { title: fr.title, body: fr.body }
    ).run!

    review = ReviewVerdictParser.parse(latest_text_event!(fr, first_review_sequence))
    fr.update!(
      review_verdict: review.verdict,
      review_body: review.body,
      last_review_seen_at: Time.current
    )
    review
  end

  def address_feedback!(fr, worktree_path, feedback)
    check_stop!(fr)
    before_count = commit_count(worktree_path, "main..HEAD")
    AgentRunner.new(
      feature_request: fr,
      worktree_path: worktree_path,
      mode: :address,
      stdin_payload: {
        title: fr.title,
        body: fr.body,
        diff: diff(worktree_path),
        feedback: feedback
      }
    ).run!

    after_count = commit_count(worktree_path, "main..HEAD")
    if after_count <= before_count
      raise NoChangesMade, "address_no_changes: agent finished without committing anything"
    end
  end

  def latest_text_event!(fr, first_sequence)
    content = fr.agent_events
                .where(kind: "text")
                .where(sequence: first_sequence..)
                .order(:sequence)
                .last
                &.payload
                &.fetch("content", nil)
    raise ReviewVerdictParser::Error, "reviewer produced no text output" if content.blank?

    content
  end

  def diff(worktree_path)
    out, err, status = Open3.capture3("git", "-C", worktree_path, "diff", "main...HEAD")
    raise MainlineLandinger::Error, "diff_failed: #{err.presence || out}" unless status.success?

    out
  end

  def commit_count(worktree_path, range)
    out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-list", "--count", range)
    status.success? ? out.strip.to_i : 0
  end
end
