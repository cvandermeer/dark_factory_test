class PollPrReviewsJob < ApplicationJob
  queue_as :default

  def perform
    FeatureRequest.where(status: "to_review", feedback_addressed: false)
                  .where.not(pr_url: nil)
                  .find_each do |fr|
      check(fr)
    end
  end

  private

  def check(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "reviews"
    )
    return unless status.success?

    reviews = JSON.parse(out).fetch("reviews", [])
    if reviews.any? { |r| r["state"] == "CHANGES_REQUESTED" }
      fr.update!(status: "review_feedback", last_review_seen_at: Time.current)
    end
  rescue => e
    Rails.logger.warn("[PollPrReviewsJob] skipping FR##{fr.id}: #{e.class}: #{e.message}")
  end
end
