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

ActiveRecord::Schema[8.1].define(version: 2026_08_02_235751) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "push_events", force: :cascade do |t|
    t.bigint "author_id"
    t.string "before"
    t.datetime "created_at", null: false
    t.text "full_info"
    t.string "github_actor_id"
    t.string "github_event_id", null: false
    t.string "github_push_id"
    t.string "github_repository_id"
    t.string "head"
    t.string "ref"
    t.boolean "repo_unenrichable", default: false, null: false
    t.bigint "repository_id"
    t.datetime "updated_at", null: false
    t.boolean "user_unenrichable", default: false, null: false
    t.index ["author_id", "user_unenrichable"], name: "index_push_events_on_author_id_and_user_unenrichable"
    t.index ["github_event_id"], name: "index_push_events_on_github_event_id", unique: true
    t.index ["repository_id", "repo_unenrichable"], name: "index_push_events_on_repository_id_and_repo_unenrichable"
  end

  create_table "repositories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.text "full_info"
    t.string "full_name"
    t.string "github_repository_id", null: false
    t.string "html_url"
    t.string "last_etag"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["github_repository_id"], name: "index_repositories_on_github_repository_id", unique: true
  end

  create_table "requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "etag"
    t.integer "poll_interval", default: 0, null: false
    t.integer "purpose", null: false
    t.integer "ratelimit_remaining"
    t.integer "ratelimit_reset"
    t.integer "retry_after"
    t.integer "status_code"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["created_at"], name: "index_requests_on_created_at"
    t.index ["purpose", "created_at"], name: "index_requests_on_purpose_and_created_at"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.text "full_info"
    t.string "github_user_id", null: false
    t.string "html_url"
    t.string "last_etag"
    t.string "login"
    t.datetime "updated_at", null: false
    t.string "user_url"
    t.index ["github_user_id"], name: "index_users_on_github_user_id", unique: true
  end

  add_foreign_key "push_events", "repositories"
  add_foreign_key "push_events", "users", column: "author_id"
end
