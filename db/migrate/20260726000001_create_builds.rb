class CreateBuilds < ActiveRecord::Migration[8.1]
  def change
    create_table :builds do |t|
      t.references :project, null: false, foreign_key: true
      t.string :state, null: false
      t.integer :duration_ms, null: false
      t.timestamps
    end

    add_index :builds, %i[project_id state]
  end
end
