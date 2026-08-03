class CreateRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :repositories do |t|
      t.string :github_repository_id, null: false
      t.string :full_name
      t.string :html_url
      t.text :description
      t.string :url
      t.string :last_etag
      t.text :full_info

      t.timestamps
    end

    add_index :repositories, :github_repository_id, unique: true
  end
end
