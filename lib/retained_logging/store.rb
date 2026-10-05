require_relative "record"
require_relative "history_summary"

module RetainedLogging
  # Persistence through Active Record alone, so each adapter's differences stay
  # inside Rails. Input is metadata History has already validated. Row locks
  # serialize writers to one lifecycle: Postgres locks the row, and SQLite's
  # immediate transactions lock the whole store.
  module Store
    # Collectors write at least every ten seconds while running. A lifecycle
    # that has written nothing for this long has lost its owner, or its owner
    # has stalled; either way its unobserved interval is reported as a gap.
    ABANDONED_SECONDS = 5 * 60

    module_function

    def start(id:, scope:, component:, at:)
      Record.transaction do
        existing = Lifecycle.lock.find_by(uuid: id)
        if existing.nil?
          Lifecycle.create!(uuid: id, scope: scope, component: component, started_at: at, seen_at: at)
          { outcome: "ok", process_id: id }
        elsif existing.scope == scope && existing.component == component && existing.started_at <= at && existing.ended_at.nil?
          # Registration may have committed before its caller gave up waiting.
          { outcome: "ok", process_id: id, started_at: existing.started_at }
        else
          invalid
        end
      end
    end

    def append(id:, scope:, events:, checkpoint:, at:)
      Record.transaction do
        lifecycle, refusal = writable(id, scope, at)
        next refusal if refusal
        next invalid if lifecycle.ended_at
        next invalid unless events.all? { |event| event["occurred_at"].between?(lifecycle.started_at, at) }
        if checkpoint
          latest = lifecycle.checkpoints.maximum(:ends_at) || lifecycle.started_at
          next invalid unless checkpoint["starts_at"] >= latest && checkpoint["ends_at"] <= at
        end
        record_events(lifecycle, scope, events, at)
        if checkpoint
          lifecycle.checkpoints.create!(checkpoint.slice("starts_at", "ends_at", "outcome", "informational_count", "unsupported_count")
            .merge("recorded_at" => at))
        end
        lifecycle.update_columns(seen_at: [ lifecycle.seen_at, at ].max)
        ok
      end
    end

    def finish(id:, scope:, at:)
      Record.transaction do
        lifecycle, refusal = writable(id, scope, at)
        next refusal if refusal
        # A completion whose caller timed out may have committed. Retrying it
        # must leave the original immutable completion intact.
        next ok if lifecycle.ended_at
        latest = lifecycle.checkpoints.maximum(:ends_at)
        next invalid if latest && latest > at
        complete(lifecycle, at)
      end
    end

    # Bounded batches keep every cleanup short. Abandoned lifecycles in this
    # scope are closed first, so the deletions below see their final state.
    def cleanup(scope:, at:, cutoff:, limit:)
      abandoned_before = at - ABANDONED_SECONDS * 1_000_000
      reconciled = Lifecycle.where(scope: scope, ended_at: nil, seen_at: ...abandoned_before, started_at: ..at)
        .order(:id).limit(limit).count { |lifecycle| close_abandoned(lifecycle.id, at, abandoned_before) }
      Record.transaction do
        events = delete_ids(Event, Event.where(occurred_at: ...cutoff).order(:occurred_at, :id).limit(limit))
        # A sample outlives neither its group nor the retention window. Expiry
        # above is not scope-limited, so neither is this.
        delete_orphan_samples if events.positive?
        checkpoints = delete_ids(Checkpoint, Checkpoint.where(ends_at: ...cutoff).order(:ends_at, :id).limit(limit))
        # Keep every lifecycle that still has a retained event or interval,
        # including intervals that cross the cutoff. A lifecycle that is still
        # writing keeps its identity even when it has recorded nothing yet.
        stale = Lifecycle.where.missing(:events, :checkpoints).where(started_at: ...cutoff)
        stale = stale.where(ended_at: ...cutoff).or(stale.where(ended_at: nil, seen_at: ...abandoned_before))
        lifecycles = delete_ids(Lifecycle, stale.limit(limit))
        { outcome: "ok", events_deleted: events, checkpoints_deleted: checkpoints, processes_deleted: lifecycles,
          processes_reconciled: reconciled }
      end
    end

    # Reads take no transaction: Rails opens SQLite transactions as IMMEDIATE,
    # which would hold the write lock and stall logging for the whole read. The
    # summary's watermarks keep its queries and later pages consistent instead.
    def summarize(scope:, snapshot:)
      HistorySummary.new(scope, snapshot).call
    end

    def writable(id, scope, at)
      lifecycle = Lifecycle.lock.find_by(uuid: id)
      # Naming an unknown lifecycle lets a collector whose identity no longer
      # exists release it and register again, instead of retrying forever.
      # A lifecycle held under another scope stays opaque.
      return [ nil, invalid.merge(reason: "unknown_process") ] unless lifecycle
      return [ nil, invalid ] unless lifecycle.scope == scope && at >= lifecycle.started_at
      [ lifecycle, nil ]
    end

    def record_events(lifecycle, scope, events, at)
      return if events.empty?
      Event.insert_all!(events.map do |event|
        { lifecycle_id: lifecycle.id, occurred_at: event["occurred_at"], recorded_at: at,
          category: event["category"], status: event["status"], pattern: event["pattern"] }
      end)
      # The first observation of an identifier keeps its sample; later ones
      # leave it alone, so a group reads the same way while it is retained.
      samples = events.select { |event| event["sample"] }.uniq { |event| event["pattern"] }
        .map { |event| { scope: scope, pattern: event["pattern"], sample: event["sample"] } }
      Sample.insert_all(samples) if samples.any?
    end

    # Observation time is a conservative upper bound, not the last good
    # checkpoint, so the unobserved interval remains a gap in summaries.
    def complete(lifecycle, at)
      lifecycle.create_completion!(ended_at: at)
      lifecycle.update_columns(ended_at: at, seen_at: [ lifecycle.seen_at, at ].max)
      ok
    end

    def close_abandoned(id, at, abandoned_before)
      Record.transaction do
        lifecycle = Lifecycle.lock.find(id)
        # The owner may have written again since the candidates were listed.
        next false unless lifecycle.ended_at.nil? && lifecycle.seen_at < abandoned_before
        latest = [ lifecycle.checkpoints.maximum(:ends_at), lifecycle.events.maximum(:occurred_at) ].compact.max
        next false if latest && latest > at
        complete(lifecycle, at)
        true
      end
    end

    def delete_orphan_samples
      events, lifecycles, samples = Event.arel_table, Lifecycle.arel_table, Sample.arel_table
      retained = Event.joins(:lifecycle).where(events[:pattern].eq(samples[:pattern])).where(lifecycles[:scope].eq(samples[:scope]))
      Sample.where.not(retained.arel.exists).delete_all
    end

    # Selecting ids first keeps the bounded delete portable across adapters.
    def delete_ids(model, relation)
      ids = relation.pluck(:id)
      ids.empty? ? 0 : model.where(id: ids).delete_all
    end

    def ok
      { outcome: "ok" }
    end

    def invalid
      { outcome: "invalid_input" }
    end
  end
end
