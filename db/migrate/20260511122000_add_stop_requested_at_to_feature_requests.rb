class AddStopRequestedAtToFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_requests, :stop_requested_at, :datetime
  end
end
