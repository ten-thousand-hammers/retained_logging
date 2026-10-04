require_relative "retained_logs"

module RetainedLogging
  # Answers whether capture is working now, from a short recent window, so a
  # deployment can be checked in minutes instead of after a full day. It reads
  # the same coverage the inspection tool reports and never prepares storage.
  class Verification
    # Checkpoints close every 10 seconds, so a window ending this far back has
    # no unfinalized tail when capture is healthy.
    SETTLE_SECONDS = 60
    MAX_DELAY_SECONDS = 60

    def initialize(history:, now: Time.now.utc)
      @history, @now = history, now
    end

    def call(minutes: 15)
      ending = Time.at((@now - SETTLE_SECONDS).to_i).utc
      result = RetainedLogs.new(history: @history, now: @now).call("component" => "all", "category" => "all",
        "lookback_minutes" => minutes, "limit" => 1, "window_end" => ending.iso8601)
      components = result.fetch("coverage").map { |coverage| component(coverage, minutes * 60) }
      { "ok" => components.all? { |entry| entry["ok"] }, "window" => result.fetch("requested_window"),
        "components" => components }
    rescue RetainedLogs::Error => error
      { "ok" => false, "error" => error.message, "components" => [] }
    end

    private

    # A gap alone does not fail verification: a deployment inside the window
    # leaves one. Capture is working when it certified part of the window, is
    # still checkpointing, and every record it saw was supported.
    def component(coverage, window_seconds)
      covered = coverage.fetch("covered_intervals").sum { |interval| Time.iso8601(interval["end"]) - Time.iso8601(interval["start"]) }
      delay = coverage["collection_delay_seconds"]
      problems = []
      problems << "nothing_captured" if covered.zero?
      problems << "not_checkpointing" if delay.nil? || delay > MAX_DELAY_SECONDS
      problems << "unsupported_input" if coverage.fetch("checkpoint_unsupported_count").positive?
      { "component" => coverage.fetch("component"), "ok" => problems.empty?, "problems" => problems,
        "covered_percent" => (100.0 * covered / window_seconds).round(1), "gaps" => coverage.fetch("gaps").size,
        "reasons" => coverage.fetch("reasons"), "collection_delay_seconds" => delay }
    end
  end
end
