require "time"
require "json"
require_relative "category_names"
require_relative "record"

module RetainedLogging
  # Reads one page of grouped events and the collection coverage behind it.
  # Every query is bounded by watermarks taken on the first page, so later
  # pages count the same rows even while collection continues.
  class HistorySummary
    DESCRIPTIONS = { "errors" => "Application error observed.", "warnings" => "Application warning observed.",
      CategoryNames::FAILED_REQUESTS_REPORTED => "Failed HTTP request observed." }.freeze
    MAX_INTERVALS = 200
    # Escaping can multiply a sample's bytes, so a page shares one serialized
    # sample allowance well inside the reader's response budget.
    SAMPLE_RESPONSE_BYTES = 120 * 1024
    GROUPING = %w[retained_logging_lifecycles.component retained_logging_events.category
      retained_logging_events.status retained_logging_events.pattern].freeze

    def initialize(scope, query)
      @scope, @query = scope, query
      @selectors = @query.fetch("selectors")
      @start, @end = @query.values_at("start", "end")
      @retained_start = @query.fetch("retained_start")
      @components = @selectors["component"] == "all" ? %w[web job] : [ @selectors["component"] ]
    end

    def call
      @watermark = @query["watermark"] || {
        "events" => Event.maximum(:id) || 0, "checkpoints" => Checkpoint.maximum(:id) || 0,
        "completions" => Completion.maximum(:id) || 0, "processes" => Lifecycle.maximum(:id) || 0
      }
      events = Event.joins(:lifecycle).where(retained_logging_lifecycles: { scope: @scope, component: @components })
        .where(occurred_at: @retained_start...@end, id: ..@watermark.fetch("events"))
      events = events.where(category: CategoryNames.stored(@selectors["category"])) unless @selectors["category"] == "all"
      groups = events.group(*GROUPING)
      total = Event.unscoped.from(groups.select(*GROUPING), :retained_groups).count
      # One samples row exists per scope and identifier, so the join adds the
      # sample without changing the grouping keys, the ordering or the total.
      samples = Sample.arel_table
      lifecycles = Lifecycle.arel_table
      join = Event.arel_table.join(samples, Arel::Nodes::OuterJoin)
        .on(samples[:scope].eq(lifecycles[:scope]).and(samples[:pattern].eq(Event.arel_table[:pattern]))).join_sources
      rows = groups.joins(join).order(*GROUPING).limit(@selectors.fetch("limit")).offset(@query.fetch("offset"))
        .pluck(*GROUPING.map { |column| Arel.sql(column) }, Arel.sql("COUNT(*)"),
          Arel.sql("MIN(retained_logging_events.occurred_at)"), Arel.sql("MAX(retained_logging_events.occurred_at)"),
          Arel.sql("MAX(retained_logging_samples.sample)"))
      remaining = SAMPLE_RESPONSE_BYTES
      summaries = rows.each_with_index.map do |(component, category, status, pattern, count, first_seen, last_seen, sample), index|
        category = CategoryNames.reported(category)
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
      lifecycles = Lifecycle.where(scope: @scope, component: component)
      latest = Checkpoint.where(lifecycle: lifecycles, id: ..@watermark.fetch("checkpoints")).maximum(:ends_at)
      completions = Completion.arel_table
      join = Lifecycle.arel_table.join(completions, Arel::Nodes::OuterJoin)
        .on(completions[:lifecycle_id].eq(Lifecycle.arel_table[:id]).and(completions[:id].lteq(@watermark.fetch("completions")))).join_sources
      processes = lifecycles.joins(join).where(id: ..@watermark.fetch("processes"), started_at: ...@end)
        .where(completions[:ended_at].eq(nil).or(completions[:ended_at].gt(@retained_start)))
        .pluck(:id, :started_at, completions[:ended_at])
      processes.each do |id, started, ended|
        cursor = [ started, @retained_start ].max
        finish = [ ended || @query.fetch("as_of"), @end ].min
        checkpoints = Checkpoint.where(lifecycle_id: id, id: ..@watermark.fetch("checkpoints"), ends_at: @retained_start.., starts_at: ...@end)
          .order(:starts_at, :id).pluck(:starts_at, :ends_at, :outcome, :informational_count, :unsupported_count)
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
