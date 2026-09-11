# Private worker. Input is validated safe metadata from History, never MCP input.
require "sqlite3"
require "json"
require_relative "history_summary"

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
        return { outcome: "unavailable" } unless [ 0, 1 ].include?(version)
        db.execute("PRAGMA journal_mode = WAL")
        transaction(db) { db.execute_batch(File.read(File.expand_path("schema.sql", __dir__))) }
        return { outcome: "ok" }
      end
      return { outcome: "unavailable" } unless version == 1
      if operation == "summarize"
        # One SQLite snapshot covers the ingestion watermark, groups and coverage.
        return db.transaction { HistorySummary.new(db, request).call }
      end
      transaction(db) do
        case operation
        when "start"
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
        when "cleanup"
          binds = request.values_at("cutoff", "limit")
          db.execute("DELETE FROM events WHERE id IN (SELECT id FROM events WHERE occurred_at < ? ORDER BY occurred_at, id LIMIT ?)", binds)
          events = db.changes
          db.execute("DELETE FROM checkpoints WHERE id IN (SELECT id FROM checkpoints WHERE ends_at < ? ORDER BY ends_at, id LIMIT ?)", binds)
          checkpoints = db.changes
          # Keep process identity/start/end for every retained event or interval, including
          # intervals that cross the cutoff. Stale, empty processes certify no coverage.
          db.execute(<<~SQL, binds)
            DELETE FROM processes WHERE id IN (
              SELECT id FROM processes WHERE started_at < ?
              AND NOT EXISTS (SELECT 1 FROM events WHERE process_id = processes.id)
              AND NOT EXISTS (SELECT 1 FROM checkpoints WHERE process_id = processes.id)
              LIMIT ?)
          SQL
          { outcome: "ok", events_deleted: events, checkpoints_deleted: checkpoints, processes_deleted: db.changes }
        else
          { outcome: "invalid_input" }
        end
      end
    end
  end
end

RetainedLogging::HistoryWorker.run if $PROGRAM_NAME == __FILE__
