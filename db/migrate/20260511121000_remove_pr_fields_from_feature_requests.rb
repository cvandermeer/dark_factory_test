class RemovePrFieldsFromFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    remove_column :feature_requests, :pr_url, :string
    remove_column :feature_requests, :pr_merged_at, :datetime
  end
end
