class AddSourceToFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_requests, :source, :string, null: false, default: "manual"
  end
end
