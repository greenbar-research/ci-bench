class ExpandBenchmarkDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :name, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true

    add_reference :projects, :owner, foreign_key: { to_table: :users }

    change_table :builds, bulk: true do |t|
      t.integer :number, null: false, default: 0
      t.string :commit_sha, null: false, default: "0000000000000000000000000000000000000000"
      t.integer :retry_count, null: false, default: 0
    end
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE builds
          SET number = numbered.number,
              commit_sha = REPEAT('0', 8) || MD5(builds.id::text)
          FROM (
            SELECT id, ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY id) AS number
            FROM builds
          ) AS numbered
          WHERE builds.id = numbered.id
        SQL
      end
    end
    change_column_default :builds, :number, from: 0, to: nil
    change_column_default :builds,
      :commit_sha,
      from: "0000000000000000000000000000000000000000",
      to: nil
    add_index :builds, %i[project_id number], unique: true

    create_table :test_cases do |t|
      t.references :build, null: false, foreign_key: true
      t.string :name, null: false
      t.string :state, null: false
      t.integer :duration_ms, null: false
      t.timestamps
    end
    add_index :test_cases, %i[build_id state]

    create_table :artifacts do |t|
      t.references :build, null: false, foreign_key: true
      t.string :name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum, null: false
      t.timestamps
    end

    create_table :audit_events do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :audit_events, %i[project_id action]
  end
end
