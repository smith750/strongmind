class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :github_user_id, null: false
      t.string :login
      t.string :avatar_url
      t.string :user_url
      t.string :html_url
      t.string :last_etag
      t.text :full_info

      t.timestamps
    end

    add_index :users, :github_user_id, unique: true
  end
end
