# Private worker. Input is validated safe metadata from History, never MCP input.
require "sqlite3"
require "json"
require_relative "history_summary"
require_relative "process_owner"

module RetainedLogging
  module HistoryWorker
    SCHEMA_VERSION = 3
    SIDECAR_SUFFIXES = [ "", "-wal", "-shm", "-journal" ].freeze

    def self.run
      request = JSON.parse($stdin.read)
      if request.fetch("operation") == "prepare"
        with_preparation_lock(request.fetch("database")) do
          discard_obsolete(request.fetch("database"))
          open_store(request)
        end
      else
        open_store(request)
      end
    rescue SQLite3::BusyException, SQLite3::LockedException
      $stdout.write('{"outcome":"contention"}')
    rescue SQLite3::FullException
      $stdout.write('{"outcome":"capacity"}')
    rescue StandardError
      $stdout.write('{"outcome":"unavailable"}')
    end

    def self.open_store(request)
      flags = request.fetch("operation") == "summarize" ? SQLite3::Constants::Open::READONLY : SQLite3::Constants::Open::READWRITE
      flags |= SQLite3::Constants::Open::CREATE if request.fetch("operation") == "prepare"
      SQLite3::Database.new(request.fetch("database"), flags: flags) do |db|
        db.busy_timeout = 100
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("PRAGMA synchronous = FULL")
        result = perform(db, request)
        $stdout.write(JSON.generate(result))
      end
    end

    # Inspecting the version, discarding an obsolete store and creating the new
    # schema are one unit. Without that, a preparation that observed an obsolete
    # version could resume after another preparation had already recreated the
    # store and unlink records written since. The lock file is never unlinked,
    # so every preparation excludes the others on the same inode. The parent
    # bounds the wait: it reports a timeout and kills a worker that waits past
    # the preparation budget, which releases the lock.
    def self.with_preparation_lock(database)
      File.open("#{database}.prepare", File::RDWR | File::CREAT, 0600) do |file|
        file.close_on_exec = true
        file.flock(File::LOCK_EX)
        yield
      end
    end

    # Retained history has no value across a schema change, so an obsolete store
    # is replaced rather than migrated. The file is unlinked before it is opened,
    # because an open handle keeps writing to the unlinked inode. The version is
    # read under the preparation lock, so a store another preparation has already
    # brought to the current version is left alone with its records.
    def self.discard_obsolete(database)
      return unless File.exist?(database)
      version = nil
      SQLite3::Database.new(database, flags: SQLite3::Constants::Open::READONLY) do |db|
        version = db.get_first_value("PRAGMA user_version")
      end
      return if version == SCHEMA_VERSION
      SIDECAR_SUFFIXES.each do |suffix|
        File.unlink("#{database}#{suffix}")
      rescue Errno::ENOENT
        # Journal and shared-memory sidecars exist only while a writer runs.
      end
      discard_owners(database)
    end

    # Discarded process rows can no longer retire their own lock files, so the
    # sweep runs here. A file whose exclusive lock is still held belongs to a
    # live process in another container and is left in place.
    def self.discard_owners(database)
      Dir.children("#{database}.owners").each do |id|
        ProcessOwner.with_abandoned(database, id) { File.unlink(ProcessOwner.path(database, id)) }
      rescue StandardError
        # A concurrent sweep may have removed the same abandoned file.
      end
    rescue Errno::ENOENT
      # No lifecycle has ever locked this store.
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
        # An obsolete store was discarded before this connection opened, so only
        # an empty new file or the current schema can reach the replay below.
        return { outcome: "unavailable" } unless [ 0, SCHEMA_VERSION ].include?(version)
        db.execute("PRAGMA journal_mode = WAL")
        transaction(db) do
          version = db.get_first_value("PRAGMA user_version")
          raise SQLite3::Exception unless [ 0, SCHEMA_VERSION ].include?(version)
          db.execute_batch(File.read(File.expand_path("schema.sql", __dir__)))
          raise SQLite3::ConstraintException unless db.execute("PRAGMA foreign_key_check").empty?
        end
        return { outcome: "ok" }
      end
      return { outcome: "unavailable" } unless version == SCHEMA_VERSION
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
              # The first observation of an identifier keeps its sample; later
              # occurrences leave it alone, so a group reads the same way as long
              # as it is retained. Occurrence rows still carry no text.
              next unless event["sample"]
              db.execute("INSERT OR IGNORE INTO patterns(scope, pattern, sample) VALUES (?, ?, ?)",
                [ request.fetch("scope"), event.fetch("pattern"), event.fetch("sample") ])
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
          # A sample outlives neither its group nor the retention window: it goes
          # as soon as the last retained occurrence of its identifier is deleted.
          # Expiry above is not scope-limited, so neither is this: no sample may
          # outlive the last retained occurrence that carries its identifier.
          if events.positive?
            db.execute(<<~SQL)
              DELETE FROM patterns WHERE NOT EXISTS (
                SELECT 1 FROM events e JOIN processes p ON p.id = e.process_id
                WHERE e.pattern = patterns.pattern AND p.scope = patterns.scope)
            SQL
          end
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
