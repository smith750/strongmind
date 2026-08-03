class CreateRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :requests do |t|
      t.string :url
      t.string :etag
      t.integer :retry_after
      t.integer :ratelimit_remaining
      t.integer :ratelimit_reset
      t.integer :poll_interval, null: false, default: 0
      t.integer :purpose, null: false
      t.integer :status_code

      t.timestamps
    end

    add_index :requests, :created_at
    add_index :requests, [ :purpose, :created_at ]
  end
end
