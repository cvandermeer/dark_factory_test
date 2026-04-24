class CreateAgentEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_events do |t|
      t.references :feature_request, null: false, foreign_key: true
      t.string :kind, null: false
      t.json :payload, null: false
      t.integer :sequence, null: false

      t.timestamps
    end

    add_index :agent_events, [:feature_request_id, :sequence], unique: true
  end
end
