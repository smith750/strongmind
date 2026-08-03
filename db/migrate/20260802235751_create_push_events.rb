class CreatePushEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :push_events do |t|
      t.string :github_push_id
      t.string :github_event_id, null: false
      t.string :github_repository_id
      t.string :ref
      t.string :head
      t.string :before
      t.string :github_actor_id
      t.text :full_info
      t.references :repository, null: true, foreign_key: true, index: false
      t.references :author, null: true, foreign_key: { to_table: :users }, index: false
      t.boolean :repo_unenrichable, null: false, default: false
      t.boolean :user_unenrichable, null: false, default: false

      t.timestamps
    end

    add_index :push_events, :github_event_id, unique: true
    add_index :push_events, [ :repository_id, :repo_unenrichable ]
    add_index :push_events, [ :author_id, :user_unenrichable ]
  end
end
