# Times are integer microseconds since the epoch, so every adapter stores and
# compares them identically, with no time zone or precision conversion.
class CreateRetainedLoggingTables < ActiveRecord::Migration[8.1]
  def change
    create_table :retained_logging_lifecycles do |t|
      t.string :uuid, null: false, limit: 36
      t.string :scope, null: false, limit: 80
      t.string :component, null: false, limit: 3
      t.bigint :started_at, null: false
      t.bigint :seen_at, null: false
      t.bigint :ended_at
      t.index :uuid, unique: true
      t.index [ :scope, :component ]
      t.check_constraint "component IN ('web', 'job')", name: "retained_logging_lifecycles_component"
      t.check_constraint "ended_at IS NULL OR ended_at >= started_at", name: "retained_logging_lifecycles_order"
    end

    create_table :retained_logging_events do |t|
      t.references :lifecycle, null: false, foreign_key: { to_table: :retained_logging_lifecycles }
      t.bigint :occurred_at, null: false
      t.bigint :recorded_at, null: false
      t.string :category, null: false, limit: 20
      t.integer :status
      t.string :pattern, null: false, limit: 80
      t.index [ :occurred_at, :id ]
      t.index :pattern
      t.check_constraint "category IN ('errors', 'warnings', 'failed_requests')", name: "retained_logging_events_category"
      t.check_constraint "status IS NULL OR status BETWEEN 400 AND 599", name: "retained_logging_events_status"
    end

    create_table :retained_logging_checkpoints do |t|
      t.references :lifecycle, null: false, index: false, foreign_key: { to_table: :retained_logging_lifecycles }
      t.bigint :starts_at, null: false
      t.bigint :ends_at, null: false
      t.bigint :recorded_at, null: false
      t.string :outcome, null: false, limit: 8
      t.integer :informational_count, null: false
      t.integer :unsupported_count, null: false
      t.index [ :ends_at, :id ]
      t.index [ :lifecycle_id, :ends_at ]
      t.check_constraint "ends_at >= starts_at", name: "retained_logging_checkpoints_order"
      t.check_constraint "outcome IN ('captured', 'gap')", name: "retained_logging_checkpoints_outcome"
    end

    create_table :retained_logging_completions do |t|
      t.references :lifecycle, null: false, index: { unique: true },
        foreign_key: { to_table: :retained_logging_lifecycles, on_delete: :cascade }
      t.bigint :ended_at, null: false
    end

    # The sample is readable text, so retention and orphan cleanup are what keep
    # it inside the 48 hour window. Its byte bound is enforced before writing.
    create_table :retained_logging_samples do |t|
      t.string :scope, null: false, limit: 80
      t.string :pattern, null: false, limit: 80
      t.text :sample, null: false
      t.index [ :scope, :pattern ], unique: true
    end
  end
end
