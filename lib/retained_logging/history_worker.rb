# Private worker. Input is validated safe metadata from History, never MCP input.
require "sqlite3"
require "json"
require_relative "history_summary"
require_relative "process_owner"

module RetainedLogging
  module HistoryWorker
    def self.run
      request = JSON.parse($stdin.read)
      flags = request.fetch("operation") == "summarize" ? SQLite3::Constants::Open::READONLY : SQLite3::Constants::Open::READWRITE
      flags |= SQLite3::Constants::Open::CREATE if request.fetch("operation") == "prepare"
      SQLite3::Database.new(request.fetch("database"), flags: flags) do |db|
        db.busy_timeout = 100
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("PRAGMA synchronous = FULL")
        result = perform(db, request)
        $stdout.write(JSON.generate(result))
      end
    rescue SQLite3::BusyException, SQLite3::LockedException
      $stdout.write('{"outcome":"contention"}')
    rescue SQLite3::FullException
      $stdout.write('{"outcome":"capacity"}')
    rescue StandardError
      $stdout.write('{"outcome":"unavailable"}')
    end

    # SQLITE_FULL may roll back automatically. The gem's transaction helper then
    # raises a second rollback error, hiding the capacity failure we must report.
    def self.transaction(db)
      db.execute("BEGIN IMMEDIATE")
      result = yield
      db.commit
      result
    ensure
      db.rollback if db.transaction_active?
    end

    def self.perform(db, request)
      operation = request.fetch("operation")
      version = db.get_first_value("PRAGMA user_version")
      if operation == "prepare"
        return { outcome: "unavailable" } unless [ 0, 1, 2 ].include?(version)
        db.execute("PRAGMA journal_mode = WAL")
        # Rebuild the parent table without cascading deletion of retained children.
        # Foreign keys must be disabled before opening the migration transaction.
        db.execute("PRAGMA foreign_keys = OFF")
        transaction(db) do
          version = db.get_first_value("PRAGMA user_version")
          raise SQLite3::Exception unless [ 0, 1, 2 ].include?(version)
          if version == 1 && !db.table_info("processes").any? { |column| column["name"] == "sequence" }
            db.execute_batch(File.read(File.expand_path("migrations/002_process_sequences.sql", __dir__)))
          end
          db.execute_batch(File.read(File.expand_path("schema.sql", __dir__)))
          raise SQLite3::ConstraintException unless db.execute("PRAGMA foreign_key_check").empty?
        end
        db.execute("PRAGMA foreign_keys = ON")
        return { outcome: "ok" }
      end
      return { outcome: "unavailable" } unless version == 2
      if operation == "summarize"
        # One SQLite snapshot covers the ingestion watermark, groups and coverage.
        return db.transaction { HistorySummary.new(db, request).call }
      end
      transaction(db) do
        case operation
        when "start"
          existing = db.get_first_row("SELECT scope, component, started_at, ended_at FROM processes WHERE id = ?", [ request.fetch("id") ])
          if existing
            return { outcome: "invalid_input" } unless existing[0] == request.fetch("scope") &&
              existing[1] == request.fetch("component") && existing[2] <= request.fetch("at") && existing[3].nil?
            return { outcome: "ok", process_id: request.fetch("id"), started_at: existing[2] }
          end
          db.execute("INSERT INTO processes(id, scope, component, started_at) VALUES (?, ?, ?, ?)",
            request.values_at("id", "scope", "component", "at"))
          { outcome: "ok", process_id: request.fetch("id") }
        when "append", "finish"
          process = db.get_first_row("SELECT started_at, ended_at FROM processes WHERE id = ? AND scope = ?", request.values_at("id", "scope"))
          return { outcome: "invalid_input" } unless process && request.fetch("at") >= process[0]
          # A timed-out completion may have committed. Retrying it must leave the
          # original immutable completion intact so recovery can proceed.
          return { outcome: "ok" } if operation == "finish" && process[1]
          return { outcome: "invalid_input" } if process[1]
          if operation == "finish"
            latest = db.get_first_value("SELECT MAX(ends_at) FROM checkpoints WHERE process_id = ?", [ request.fetch("id") ])
            return { outcome: "invalid_input" } if latest && latest > request.fetch("at")
            db.execute("INSERT INTO completions(process_id, ended_at) VALUES (?, ?)", request.values_at("id", "at"))
            db.execute("UPDATE processes SET ended_at = ? WHERE id = ?", request.values_at("at", "id"))
          else
            events = request.fetch("events")
            checkpoint = request["checkpoint"]
            return { outcome: "invalid_input" } unless events.all? { |event| event["occurred_at"].between?(process[0], request.fetch("at")) }
            if checkpoint
              latest = db.get_first_value("SELECT MAX(ends_at) FROM checkpoints WHERE process_id = ?", [ request.fetch("id") ]) || process[0]
              return { outcome: "invalid_input" } unless checkpoint["starts_at"] >= latest && checkpoint["ends_at"] <= request.fetch("at")
            end
            events.each do |event|
              db.execute("INSERT INTO events(process_id, occurred_at, recorded_at, category, status, pattern) VALUES (?, ?, ?, ?, ?, ?)",
                [ request.fetch("id"), event.fetch("occurred_at"), request.fetch("at"), *event.values_at("category", "status", "pattern") ])
            end
            if checkpoint
              db.execute("INSERT INTO checkpoints(process_id, starts_at, ends_at, recorded_at, outcome, informational_count, unsupported_count) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [ request.fetch("id"), *checkpoint.values_at("starts_at", "ends_at"), request.fetch("at"), *checkpoint.values_at("outcome", "informational_count", "unsupported_count") ])
            end
          end
          { outcome: "ok" }
        when "reconcile"
          process = db.get_first_row("SELECT started_at, ended_at FROM processes WHERE id = ? AND scope = ?", request.values_at("id", "scope"))
          return { outcome: "invalid_input" } unless process && request.fetch("at") >= process[0]
          return { outcome: "ok" } if process[1]
          result = { outcome: "contention" }
          ProcessOwner.with_abandoned(request.fetch("database"), request.fetch("id"), legacy: true) do
            result = complete_abandoned(db, request.fetch("id"), request.fetch("at"))
          end
          result
        when "cleanup"
          reconciled = reconcile_abandoned(db, request)
          binds = request.values_at("cutoff", "limit")
          db.execute("DELETE FROM events WHERE id IN (SELECT id FROM events WHERE occurred_at < ? ORDER BY occurred_at, id LIMIT ?)", binds)
          events = db.changes
          db.execute("DELETE FROM checkpoints WHERE id IN (SELECT id FROM checkpoints WHERE ends_at < ? ORDER BY ends_at, id LIMIT ?)", binds)
          checkpoints = db.changes
          # Keep process identity/start/end for every retained event or interval, including
          # intervals that cross the cutoff. Stale, empty processes certify no coverage.
          processes = 0
          db.execute(<<~SQL, [ request.fetch("cutoff"), request.fetch("cutoff"), request.fetch("limit") ]).each do |id, ended|
              SELECT id, ended_at FROM processes WHERE started_at < ?
              AND (ended_at IS NULL OR ended_at < ?)
              AND NOT EXISTS (SELECT 1 FROM events WHERE process_id = processes.id)
              AND NOT EXISTS (SELECT 1 FROM checkpoints WHERE process_id = processes.id)
              LIMIT ?
          SQL
            owner_path = ProcessOwner.path(request.fetch("database"), id)
            # Cleanup must not erase a stalled, still-owned process identity.
            # Recent completions also retain their uncheckpointed gap above.
            next if ended.nil? && File.exist?(owner_path)
            db.execute("DELETE FROM processes WHERE id = ?", [ id ])
            processes += db.changes
            File.unlink(owner_path) if File.exist?(owner_path)
          end
          { outcome: "ok", events_deleted: events, checkpoints_deleted: checkpoints, processes_deleted: processes,
            processes_reconciled: reconciled }
        else
          { outcome: "invalid_input" }
        end
      end
    end

    def self.reconcile_abandoned(db, request)
      reconciled = 0
      # Keep the existing cleanup transaction and worker deadline. A live owner
      # is skipped immediately, even if it has not checkpointed for hours.
      db.execute(<<~SQL, [ request.fetch("scope"), request.fetch("at"), request.fetch("limit") ]).each do |id, _|
        SELECT id FROM processes WHERE scope = ? AND ended_at IS NULL AND started_at <= ?
        ORDER BY sequence LIMIT ?
      SQL
        ProcessOwner.with_abandoned(request.fetch("database"), id) do
          # An owner can exit while cleanup starts its worker. Use the time of
          # the lock observation, not the earlier request time. The offset keeps
          # an explicitly supplied maintenance clock consistent across processes.
          observed_at = [ request.fetch("at"), (Time.now.to_r * 1_000_000).to_i + request.fetch("clock_offset") ].max
          reconciled += 1 if complete_abandoned(db, id, observed_at)[:outcome] == "ok"
        end
      end
      reconciled
    end

    def self.complete_abandoned(db, id, at)
      latest = db.get_first_value(<<~SQL, [ id, id ])
        SELECT MAX(at) FROM (
          SELECT MAX(ends_at) AS at FROM checkpoints WHERE process_id = ?
          UNION ALL SELECT MAX(occurred_at) AS at FROM events WHERE process_id = ?)
      SQL
      return { outcome: "invalid_input" } if latest && latest > at
      # Observation time is a conservative upper bound, not the last good
      # checkpoint. The unobserved interval remains a gap in summaries.
      db.execute("INSERT INTO completions(process_id, ended_at) VALUES (?, ?)", [ id, at ])
      db.execute("UPDATE processes SET ended_at = ? WHERE id = ?", [ at, id ])
      { outcome: "ok" }
    end
  end
end

RetainedLogging::HistoryWorker.run if $PROGRAM_NAME == __FILE__
