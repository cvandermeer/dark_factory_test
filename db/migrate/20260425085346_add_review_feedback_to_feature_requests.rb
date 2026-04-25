class AddReviewFeedbackToFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_requests, :feedback_addressed, :boolean, null: false, default: false
    add_column :feature_requests, :last_review_seen_at, :datetime
  end
end
