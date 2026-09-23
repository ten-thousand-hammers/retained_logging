require "time"
require "json"

module RetainedLogging
  # Runs in the cancellable read-only history worker, never on a Rails connection.
  class HistorySummary
    DESCRIPTIONS = { "errors" => "Application error observed.", "warnings" => "Application warning observed.",
      "request_failures" => "Failed HTTP request observed." }.freeze
    MAX_INTERVALS = 200
    # Escaping can multiply a sample's bytes, so a page shares one serialized
    # sample allowance well inside the reader's response budget.
    SAMPLE_RESPONSE_BYTES = 120 * 1024

    def initialize(db, request)
      @db, @scope, @query = db, request.fetch("scope"), request.fetch("snapshot")
      @selectors = @query.fetch("selectors")
      @start, @end = @query.values_at("start", "end")
      @retained_start = @query.fetch("retained_start")
      @components = @selectors["component"] == "all" ? %w[web job] : [ @selectors["component"] ]
    end

    def call
      @watermark = @query["watermark"] || {
        "events" => @db.get_first_value("SELECT COALESCE(MAX(id), 0) FROM events"),
        "checkpoints" => @db.get_first_value("SELECT COALESCE(MAX(id), 0) FROM checkpoints"),
        "completions" => @db.get_first_value("SELECT COALESCE(MAX(id), 0) FROM completions"),
        "processes" => @db.get_first_value("SELECT COALESCE(MAX(sequence), 0) FROM processes")
      }
      predicates = [ "p.scope = ?", "p.component IN (#{([ '?' ] * @components.size).join(', ')})",
        "e.occurred_at >= ?", "e.occurred_at < ?", "e.id <= ?" ]
      binds = [ @scope, *@components, @retained_start, @end, @watermark.fetch("events") ]
      unless @selectors["category"] == "all"
        predicates << "e.category = ?"
        binds << (@selectors["category"] == "request_failures" ? "failed_requests" : @selectors["category"])
      end
      # One patterns row exists per scope and identifier, so the join adds the
      # sample without changing the grouping keys, the ordering or the total.
      grouped = <<~SQL
        SELECT p.component, e.category, e.status, e.pattern, COUNT(*) AS count,
          MIN(e.occurred_at) AS first_seen, MAX(e.occurred_at) AS last_seen, MAX(s.sample) AS sample
        FROM events e JOIN processes p ON p.id = e.process_id
        LEFT JOIN patterns s ON s.scope = p.scope AND s.pattern = e.pattern
        WHERE #{predicates.join(' AND ')}
        GROUP BY p.component, e.category, e.status, e.pattern
      SQL
      total = @db.get_first_value("SELECT COUNT(*) FROM (#{grouped})", binds)
      rows = @db.execute("#{grouped} ORDER BY p.component, e.category, e.status, e.pattern LIMIT ? OFFSET ?",
        [ *binds, @selectors.fetch("limit"), @query.fetch("offset") ])
      remaining = SAMPLE_RESPONSE_BYTES
      summaries = rows.each_with_index.map do |(component, category, status, pattern, count, first_seen, last_seen, sample), index|
        category = "request_failures" if category == "failed_requests"
        sample = fit(sample, remaining / (rows.size - index))
        remaining -= serialized(sample) if sample
        { component: component, category: category, status: status, pattern: pattern, count: count,
          first_seen: iso(first_seen), last_seen: iso(last_seen), description: DESCRIPTIONS.fetch(category),
          sample: sample }
      end
      { outcome: "ok", watermark: @watermark, summaries: summaries, total_groups: total,
        coverage: @components.map { |component| coverage(component) } }
    end

    private

    # A page of maximum-length samples must return rather than exceed the
    # reader's response budget, so a sample is shortened to a valid prefix
    # whenever its escaped form claims more than its share of the allowance.
    def fit(sample, allowance)
      return if sample.nil?
      sample = sample.scrub
      while (escaped = serialized(sample)) > allowance && !sample.empty?
        sample = clip(sample, [ sample.bytesize * allowance / escaped, sample.bytesize - 1 ].min)
      end
      sample
    end

    def serialized(sample)
      JSON.generate([ sample ]).bytesize
    end

    def clip(text, bytes)
      text = text.byteslice(0, [ bytes, 0 ].max)
      text = text.byteslice(0, text.bytesize - 1) until text.empty? || text.valid_encoding?
      text
    end

    def coverage(component)
      captured, uncertain, reasons = [], [], []
      informational = unsupported = 0
      latest = @db.get_first_value(<<~SQL, [ @scope, component, @watermark.fetch("checkpoints") ])
        SELECT MAX(c.ends_at) FROM checkpoints c JOIN processes p ON p.id = c.process_id
        WHERE p.scope = ? AND p.component = ? AND c.id <= ?
      SQL
      processes = @db.execute(<<~SQL, [ @watermark.fetch("completions"), @scope, component, @watermark.fetch("processes"), @end, @retained_start ])
        SELECT p.id, p.started_at, c.ended_at FROM processes p
        LEFT JOIN completions c ON c.process_id = p.id AND c.id <= ?
        WHERE p.scope = ? AND p.component = ? AND p.sequence <= ? AND p.started_at < ?
          AND (c.ended_at IS NULL OR c.ended_at > ?)
      SQL
      processes.each do |id, started, ended|
        cursor = [ started, @retained_start ].max
        finish = [ ended || @query.fetch("as_of"), @end ].min
        checkpoints = @db.execute(<<~SQL, [ id, @watermark.fetch("checkpoints"), @retained_start, @end ])
          SELECT starts_at, ends_at, outcome, informational_count, unsupported_count FROM checkpoints
          WHERE process_id = ? AND id <= ? AND ends_at >= ? AND starts_at < ? ORDER BY starts_at, id
        SQL
        checkpoints.each do |from, to, outcome, info, unknown|
          left, right = [ from, @retained_start ].max, [ to, finish ].min
          next unless left < right
          if left > cursor
            uncertain << [ cursor, left ]
            reasons << "interrupted_capture"
          end
          if outcome == "captured" && unknown.zero?
            captured << [ left, right ]
          else
            uncertain << [ left, right ]
            reasons << (unknown.positive? ? "unsupported_input" : "collection_gap")
          end
          # These are whole overlapping-checkpoint counts, not prorated event
          # totals; checkpoints deliberately retain no per-message INFO records.
          informational += info
          unsupported += unknown
          cursor = [ cursor, right ].max
        end
        if cursor < finish
          uncertain << [ cursor, finish ]
          reasons << (ended ? "interrupted_capture" : "unfinalized_tail")
        end
      end
      # Sweep all processes together: a successful replica cannot certify another
      # replica's failed or unfinalized collection interval.
      boundaries = Hash.new { |hash, key| hash[key] = [ 0, 0 ] }
      boundaries[@start]
      boundaries[@end]
      [ captured, uncertain ].each_with_index do |intervals, index|
        intervals.each do |from, to|
          boundaries[from][index] += 1
          boundaries[to][index] -= 1
        end
      end
      covered, gaps = [], []
      active = [ 0, 0 ]
      boundaries.keys.sort.each_cons(2) do |from, to|
        active = active.zip(boundaries[from]).map { |a, b| a + b }
        target = active[0].positive? && active[1].zero? ? covered : gaps
        if target.last && target.last[1] == from
          target.last[1] = to
        else
          target << [ from, to ]
        end
      end
      reasons << "expired_history" if @start < @retained_start
      reasons << "missing_component" if processes.empty?
      reasons << "warm_up" if processes.any? && processes.map { |process| process[1] }.min > @retained_start
      reasons << "collection_not_established" if gaps.any? && reasons.empty?
      { component: component, source: "retained_application", availability: gaps.empty? ? "complete" : "partial",
        covered_intervals: intervals(covered), gaps: intervals(gaps), reasons: reasons.uniq.sort,
        intervals_truncated: covered.size > MAX_INTERVALS || gaps.size > MAX_INTERVALS,
        collection_delay_seconds: latest ? [ (@query.fetch("as_of") - latest) / 1_000_000.0, 0 ].max : nil,
        checkpoint_informational_count: informational, checkpoint_unsupported_count: unsupported }
    end

    def intervals(values)
      values.first(MAX_INTERVALS).map { |from, to| { start: iso(from), end: iso(to) } }
    end

    def iso(value)
      Time.at(Rational(value, 1_000_000)).utc.iso8601(6)
    end
  end
end
