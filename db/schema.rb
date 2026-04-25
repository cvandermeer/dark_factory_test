# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_25_085346) do
  create_table "agent_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "feature_request_id", null: false
    t.string "kind", null: false
    t.json "payload", null: false
    t.integer "sequence", null: false
    t.datetime "updated_at", null: false
    t.index ["feature_request_id", "sequence"], name: "index_agent_events_on_feature_request_id_and_sequence", unique: true
    t.index ["feature_request_id"], name: "index_agent_events_on_feature_request_id"
  end

  create_table "feature_requests", force: :cascade do |t|
    t.text "body", null: false
    t.string "branch_name"
    t.datetime "created_at", null: false
    t.text "failure_reason"
    t.boolean "feedback_addressed", default: false, null: false
    t.datetime "last_review_seen_at"
    t.datetime "pr_merged_at"
    t.string "pr_url"
    t.string "status", default: "todo", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_feature_requests_on_status"
  end

  add_foreign_key "agent_events", "feature_requests"
end
