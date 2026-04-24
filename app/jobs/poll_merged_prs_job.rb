class PollMergedPrsJob < ApplicationJob
  queue_as :default

  def perform
    FeatureRequest.to_review
                  .where.not(pr_url: nil)
                  .where(pr_merged_at: nil)
                  .find_each do |fr|
      check(fr)
    end
  end

  private

  def check(fr)
    out, _err, status = Open3.capture3(
      { "GH_TOKEN" => ENV["GH_TOKEN"] }.compact,
      "gh", "pr", "view", fr.pr_url, "--json", "mergedAt,state"
    )
    return unless status.success?

    data = JSON.parse(out)
    merged_at = data["mergedAt"]
    if merged_at.present?
      fr.update!(pr_merged_at: Time.parse(merged_at))
    end
  rescue => e
    Rails.logger.warn("[PollMergedPrsJob] skipping FR##{fr.id}: #{e.class}: #{e.message}")
  end
end
