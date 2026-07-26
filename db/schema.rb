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

ActiveRecord::Schema[8.1].define(version: 2026_07_26_161723) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "artifacts", force: :cascade do |t|
    t.bigint "build_id", null: false
    t.bigint "byte_size", null: false
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["build_id"], name: "index_artifacts_on_build_id"
  end

  create_table "audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["project_id", "action"], name: "index_audit_events_on_project_id_and_action"
    t.index ["project_id"], name: "index_audit_events_on_project_id"
    t.index ["user_id"], name: "index_audit_events_on_user_id"
  end

  create_table "builds", force: :cascade do |t|
    t.string "commit_sha", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms", null: false
    t.integer "number", null: false
    t.bigint "project_id", null: false
    t.integer "retry_count", default: 0, null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "number"], name: "index_builds_on_project_id_and_number", unique: true
    t.index ["project_id", "state"], name: "index_builds_on_project_id_and_state"
    t.index ["project_id"], name: "index_builds_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "owner_id"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_projects_on_name", unique: true
    t.index ["owner_id"], name: "index_projects_on_owner_id"
  end

  create_table "test_cases", force: :cascade do |t|
    t.bigint "build_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms", null: false
    t.string "name", null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["build_id", "state"], name: "index_test_cases_on_build_id_and_state"
    t.index ["build_id"], name: "index_test_cases_on_build_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "artifacts", "builds"
  add_foreign_key "audit_events", "projects"
  add_foreign_key "audit_events", "users"
  add_foreign_key "builds", "projects"
  add_foreign_key "projects", "users", column: "owner_id"
  add_foreign_key "test_cases", "builds"
end
