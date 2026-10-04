require "time"
require "date"
require_relative "history"
require_relative "category_names"
require_relative "log_arguments"

module RetainedLogging
  # Application history only. The MCP adapter combines platform evidence separately.
  class RetainedLogs
    CATEGORIES = [ "errors", "warnings", CategoryNames::FAILED_REQUESTS_REPORTED ].freeze
    CURSOR_SECONDS = 900
    class Error < StandardError; end

    def self.validate!(arguments)
      raise Error, "invalid_arguments" unless LogArguments.valid?(arguments)
    end

    def self.utc_time(value)
      LogArguments.utc_time(value)
    end

    def initialize(history:, now: Time.now.utc)
      @history, @now = history, now
    end

    # Half-open windows [start, end) keep adjacent audit windows disjoint.
    # Cursors live at most 15 minutes, and expire sooner if retention overtakes
    # their window. This prevents cleanup from silently changing page counts.
    def call(arguments)
      self.class.validate!(arguments)
      selectors = { "component" => arguments.fetch("component", "all"), "category" => arguments.fetch("category", "all"),
        "lookback_minutes" => arguments.fetch("lookback_minutes", 15), "limit" => arguments.fetch("limit", 25),
        "window_end" => arguments["window_end"] }
      cutoff = micros(@now) - History::RETENTION_SECONDS * 1_000_000
      if arguments.key?("continuation")
        snapshot = @history.decode_cursor(arguments["continuation"])
        raise Error, "invalid_cursor" unless snapshot && snapshot["selectors"] == selectors &&
          snapshot["expires_at"] > micros(@now) && snapshot["retained_start"] >= cutoff
      else
        ending = arguments.key?("window_end") ? self.class.utc_time(arguments["window_end"]) : @now
        raise Error, "invalid_window" unless ending <= @now && micros(ending) > cutoff
        snapshot = { "selectors" => selectors, "start" => micros(ending) - selectors["lookback_minutes"] * 60_000_000,
          "end" => micros(ending), "as_of" => micros(@now), "expires_at" => micros(@now + CURSOR_SECONDS), "offset" => 0 }
        snapshot["retained_start"] = [ snapshot["start"], cutoff ].max
      end
      result = @history.summarize(snapshot)
      raise Error, "history_#{result['outcome']}" unless result["outcome"] == "ok"
      snapshot["watermark"] ||= result.fetch("watermark")
      snapshot["offset"] += result.fetch("summaries").size
      more = snapshot["offset"] < result.fetch("total_groups")
      result.except("outcome", "watermark").merge("requested_window" => { "start" => iso(snapshot["start"]), "end" => iso(snapshot["end"]) },
        "truncated" => more, "continuation" => more ? @history.encode_cursor(snapshot) : nil)
    end

    private

    def micros(time)
      (time.to_r * 1_000_000).to_i
    end

    def iso(value)
      Time.at(Rational(value, 1_000_000)).utc.iso8601(6)
    end
  end
end
