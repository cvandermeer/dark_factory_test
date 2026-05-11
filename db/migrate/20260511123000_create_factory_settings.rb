class CreateFactorySettings < ActiveRecord::Migration[8.1]
  def change
    create_table :factory_settings do |t|
      t.string :mode, null: false, default: "manual"
      t.datetime :automatic_started_at

      t.timestamps
    end
  end
end
