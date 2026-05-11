class AddAutonomousLandingFieldsToFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_requests, :landed_commit_sha, :string
    add_column :feature_requests, :review_verdict, :string
    add_column :feature_requests, :review_body, :text
  end
end
