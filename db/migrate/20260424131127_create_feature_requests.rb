class CreateFeatureRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_requests do |t|
      t.string :title, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "todo"
      t.string :branch_name
      t.string :pr_url
      t.datetime :pr_merged_at
      t.text :failure_reason

      t.timestamps
    end

    add_index :feature_requests, :status
  end
end
