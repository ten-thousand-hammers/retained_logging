require "minitest/autorun"
require "retained_logging"
require "active_support/tagged_logging"
require "active_support/testing/time_helpers"
require "stringio"
require "tmpdir"
require "fileutils"
require "sqlite3"
require "rubygems/package"

class RetainedLoggingTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  class Collector
    attr_reader :records, :interruptions

    def initialize
      @records = []
      @interruptions = 0
    end

    def record(*metadata)
      @records << metadata
    end

    def observe_sources(_sources); end

    def interrupt
      @interruptions += 1
    end
  end

  def setup
    @output = StringIO.new
    @original = ActiveSupport::TaggedLogging.logger(@output)
    @collector = Collector.new
    @logger = RetainedLogging::Capture.install(@original, @collector)
  end

  def test_public_broadcast_preserves_tags_lazy_blocks_and_unformatted_patterns
    calls = 0
    @logger.tagged("request-secret") do |tagged|
      assert_same @logger, tagged
      assert_equal true, tagged.error { calls += 1; "Completed 503 Service Unavailable" }
      tagged.tagged("nested-secret").warn { calls += 1; "warning" }
    end
    @logger.info("untagged")
    assert_equal 2, calls
    assert_equal [ "Completed 503 Service Unavailable", "warning", "untagged" ], @collector.records.map(&:last)
    assert_equal [ "ERROR", "WARN", "INFO" ], @collector.records.map(&:first)
    assert_equal "[request-secret] Completed 503 Service Unavailable\n[request-secret] [nested-secret] warning\nuntagged\n", @output.string
  end

  def test_filtered_blocks_and_temporary_silence_keep_original_behavior
    calls = 0
    @logger.level = Logger::ERROR
    assert_equal true, @logger.warn { calls += 1; "filtered" }
    @logger.error { calls += 1; "visible" }
    @logger.silence(Logger::FATAL) do
      refute @logger.error?
      @logger.error { calls += 1; "silenced" }
    end
    assert @logger.error?
    assert_equal 1, calls
    assert_equal [ "visible" ], @collector.records.map(&:last)
    assert_equal "visible\n", @output.string
  end

  def test_reinstallation_and_multiple_destinations_capture_each_call_once
    second_output = StringIO.new
    second = ActiveSupport::TaggedLogging.logger(second_output)
    @logger = RetainedLogging::Capture.install(ActiveSupport::BroadcastLogger.new(@logger, second), @collector)
    3.times { assert_same @logger, RetainedLogging::Capture.install(@logger, @collector) }
    calls = 0
    @logger.tagged("tag") { |logger| logger.error { calls += 1; "signal" } }
    assert_equal 1, calls
    assert_equal 1, @collector.records.size
    assert_equal "[tag] signal\n", @output.string
    assert_equal @output.string, second_output.string
  end

  def test_add_log_progname_exception_and_formatter_contracts
    @original.progname = "default program"
    @logger.add(Logger::ERROR, nil, "program")
    @logger.log(Logger::WARN) { "block message" }
    @logger.error
    error = StandardError.new("exception sentinel")
    @logger.error(error)
    @logger.formatter = ->(_severity, _time, _program, message) { "formatted: #{message}\n" }
    @logger.warn("raw pattern")
    assert_equal [ "program", "block message", "default program", error, "raw pattern" ], @collector.records.map(&:last)
    assert_includes @output.string, "formatted: raw pattern"
  end

  def test_capture_exception_preserves_output_and_marks_interruption_without_diagnostics
    @collector.define_singleton_method(:record) { |*| raise "credential=collector-secret" }
    assert_equal true, @logger.error("application message")
    assert_equal "application message\n", @output.string
    assert_equal 1, @collector.interruptions
  end

  def test_application_block_exception_is_not_swallowed_or_repeated
    calls = 0
    error = assert_raises(RuntimeError) do
      @logger.error { calls += 1; raise "application block error" }
    end
    assert_equal "application block error", error.message
    assert_equal 1, calls
    assert_empty @collector.records
    assert_equal 0, @collector.interruptions
  end

  def test_capture_receives_metadata_before_output_formatting
    @original.formatter = lambda do |_severity, _time, _progname, message|
      assert_equal [ "message" ], @collector.records.map(&:last)
      "formatted #{message}\n"
    end
    assert_same @original.formatter, @logger.formatter
    @logger.error("message")
    assert_equal "formatted message\n", @output.string
  end

  def test_real_capture_reopens_safe_history_and_reports_failed_collection
    Dir.mktmpdir do |directory|
      path = File.join(directory, "history.sqlite3")
      history = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      assert_equal "ok", history.prepare["outcome"]
      now = Time.utc(2026, 9, 11, 12)
      capture = RetainedLogging::Capture.new(history: history, component: "job", clock: -> { now }, background: false)
      logger = RetainedLogging::Capture.install(@original, capture)
      capture.start
      2.times do
        now += 10
        travel_to(now) { logger.error("credential=sentinel\nprivate.rb:42") }
        capture.checkpoint
      end
      # An unavailable store preserves output and leaves the failed interval open.
      append = history.method(:append)
      history.define_singleton_method(:append) { |**| { "outcome" => "capacity" } }
      now += 10
      travel_to(now) { logger.error("failed write") }
      history.define_singleton_method(:append, append)
      now += 10
      capture.checkpoint
      now += 10
      capture.checkpoint
      now += 10
      capture.stop
      reopened = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      result = RetainedLogging::RetainedLogs.new(history: reopened, now: now).call("component" => "job", "lookback_minutes" => 1)
      assert_equal 1, result["total_groups"]
      assert_equal 2, result["summaries"].first["count"]
      assert_equal "2026-09-11T12:00:10.000000Z", result["summaries"].first["first_seen"]
      assert_equal "2026-09-11T12:00:20.000000Z", result["summaries"].first["last_seen"]
      coverage = result["coverage"].first
      assert_equal "partial", coverage["availability"]
      assert_equal [ { "start" => "2026-09-11T12:00:20.000000Z", "end" => "2026-09-11T12:00:40.000000Z" } ], coverage["gaps"]
      # The group is readable, and the occurrence rows themselves still hold no text.
      assert_equal "credential=sentinel\nprivate.rb:42", result["summaries"].first["sample"]
      SQLite3::Database.new(path, readonly: true) do |db|
        assert_empty db.execute("SELECT * FROM events").flatten.grep(/sentinel/)
        assert_equal [ "credential=sentinel\nprivate.rb:42" ], db.execute("SELECT sample FROM patterns").flatten
      end
      assert_includes @output.string, "failed write"
      assert_equal "ok", reopened.cleanup(at: now)["outcome"]
    end
  end

  def test_variable_text_shares_one_group_while_wording_and_fixed_labels_stay_separate
    Dir.mktmpdir do |directory|
      path = File.join(directory, "history.sqlite3")
      history = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      assert_equal "ok", history.prepare["outcome"]
      now = Time.utc(2026, 9, 11, 12)
      id = history.start_process(component: "web", at: now).fetch("process_id")
      pairs = [
        [ "Search 12 timed out", "Search 3841 timed out" ],
        [ "Digest 9f8e7d6c5b4a3210 mismatched", "Digest 0123456789abcdef mismatched" ],
        [ "Grab 550e8400-e29b-41d4-a716-446655440000 retried", "Grab 6ba7b810-9dad-11d1-80b4-00c04fd430c8 retried" ],
        [ "Indexer answered in 250ms", "Indexer answered in 4.5 seconds" ],
        [ "Import failed for /srv/media/one.mkv", "Import failed for /var/lib/grabarr/two-copy.mkv" ],
        [ "Queue drained 9999999 records", "Queue drained 10000000 records" ],
        [ "Copy failed for /srv/media/café.mkv", "Copy failed for /srv/media/été.mkv" ],
        [ %(Move failed for "/srv/media/First Film.mkv" now), %(Move failed for "/srv/media/Second Movie.mkv" now) ]
      ]
      events = pairs.flatten.map { |message| history.event(at: now, category: "warnings", message: message) }
      patterns = events.map { |event| event.fetch("pattern") }
      assert_equal 8, patterns.uniq.size
      assert_equal patterns.each_slice(2).map(&:uniq).map(&:size), [ 1 ] * 8
      failed = history.event(at: now, category: "failed_requests", status: 503, label: "failed_request",
        message: "Completed 503 Service Unavailable in 7ms")
      assert_equal "label:v1:failed_request", failed["pattern"]
      assert_equal "ok", history.append(process_id: id, events: events + [ failed ], at: now)["outcome"]
      result = RetainedLogging::RetainedLogs.new(history: history, now: now + 1).call("component" => "web", "lookback_minutes" => 1)
      assert_equal 9, result["total_groups"]
      assert_equal [ 1 ] + [ 2 ] * 8, result["summaries"].map { |group| group["count"] }.sort
      assert_equal [ 503 ], result["summaries"].filter_map { |group| group["status"] }
    end
  end

  def test_sample_keeps_the_first_message_is_bounded_and_expires_with_its_group
    Dir.mktmpdir do |directory|
      path = File.join(directory, "history.sqlite3")
      history = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      assert_equal "ok", history.prepare["outcome"]
      now = Time.utc(2026, 9, 11, 12)
      id = history.start_process(component: "web", at: now).fetch("process_id")
      # A multi-byte character straddles the 512 byte bound of the long message.
      long = "Import failed for #{'a' * 493}é tail"
      events = [ history.event(at: now, category: "warnings", message: "Import failed for /srv/one.mkv"),
        history.event(at: now, category: "warnings", message: "Import failed for /srv/two.mkv"),
        history.event(at: now, category: "warnings", message: long) ]
      assert_equal "Import failed for /srv/one.mkv", events.first["sample"]
      # The bound falls inside the multi-byte character, which is dropped whole.
      assert_equal 511, events.last["sample"].bytesize
      assert events.last["sample"].valid_encoding?
      assert_equal "ok", history.append(process_id: id, events: events, at: now)["outcome"]
      result = RetainedLogging::RetainedLogs.new(history: history, now: now + 1).call("lookback_minutes" => 1)
      assert_equal 2, result["total_groups"]
      grouped = result["summaries"].find { |group| group["count"] == 2 }
      assert_equal "Import failed for /srv/one.mkv", grouped["sample"]
      assert_equal events.last["sample"], result["summaries"].find { |group| group["count"] == 1 }["sample"]
      # An oversized or mistyped sample never reaches the worker.
      [ "x" * 513, 42, nil ].each do |sample|
        assert_equal "invalid_input", history.append(process_id: id, events: [ events.first.merge("sample" => sample) ], at: now)["outcome"]
      end
      assert_equal 2, sample_rows(path).size
      assert_equal "ok", history.cleanup(at: now + 49 * 60 * 60)["outcome"]
      assert_empty sample_rows(path)
    end
  end

  def test_verification_passes_live_capture_and_names_what_is_missing
    Dir.mktmpdir do |directory|
      path = File.join(directory, "history.sqlite3")
      history = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      unprepared = RetainedLogging::Verification.new(history: history, now: Time.utc(2026, 9, 11, 12, 20)).call(minutes: 15)
      assert_equal({ "ok" => false, "error" => "history_unavailable", "components" => [] }, unprepared)

      assert_equal "ok", history.prepare["outcome"]
      started = Time.utc(2026, 9, 11, 12)
      micros = ->(time) { (time.to_r * 1_000_000).to_i }
      checkpoint = lambda do |id, from, to, unsupported: 0|
        { "starts_at" => micros.(from), "ends_at" => micros.(to), "outcome" => "captured",
          "informational_count" => 3, "unsupported_count" => unsupported }
      end
      web = history.start_process(component: "web", at: started).fetch("process_id")
      job = history.start_process(component: "job", at: started).fetch("process_id")
      # Web checkpoints until 12:20; job stopped checkpointing at 12:10.
      (0...120).each do |step|
        from, to = started + step * 10, started + (step + 1) * 10
        assert_equal "ok", history.append(process_id: web, checkpoint: checkpoint.(web, from, to), at: to)["outcome"]
        next if to > started + 600
        assert_equal "ok", history.append(process_id: job, checkpoint: checkpoint.(job, from, to), at: to)["outcome"]
      end

      report = RetainedLogging::Verification.new(history: history, now: started + 1205).call(minutes: 5)
      refute report["ok"]
      assert_equal({ "start" => "2026-09-11T12:14:05.000000Z", "end" => "2026-09-11T12:19:05.000000Z" }, report["window"])
      web_entry, job_entry = report["components"].sort_by { |entry| entry["component"] }.reverse
      assert_equal [ "web", true, [], 100.0 ], web_entry.values_at("component", "ok", "problems", "covered_percent")
      assert_equal [ "job", false, %w[nothing_captured not_checkpointing], 0.0 ],
        job_entry.values_at("component", "ok", "problems", "covered_percent")

      # A longer window reaches back to the job's last captured interval.
      report = RetainedLogging::Verification.new(history: history, now: started + 1205).call(minutes: 15)
      job_entry = report["components"].find { |entry| entry["component"] == "job" }
      assert_equal [ "not_checkpointing" ], job_entry["problems"]
      assert_operator job_entry["covered_percent"], :>, 0
    end
  end

  def test_obsolete_store_is_discarded_with_its_abandoned_locks_while_a_live_lock_survives
    Dir.mktmpdir do |directory|
      path = File.join(directory, "history.sqlite3")
      history = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      assert_equal "ok", history.prepare["outcome"]
      now = Time.utc(2026, 9, 11, 12)
      abandoned = history.acquire_owner
      history.start_process(component: "web", at: now, owner: abandoned)
      abandoned.close
      live = history.acquire_owner
      history.start_process(component: "job", at: now, owner: live)
      # A store left at a version that cannot be upgraded is replaced, not migrated.
      SQLite3::Database.new(path) { |db| db.execute("PRAGMA user_version = 1") }
      assert_equal "ok", history.prepare["outcome"]
      SQLite3::Database.new(path, readonly: true) do |db|
        assert_equal 3, db.get_first_value("PRAGMA user_version")
        assert_equal 0, db.get_first_value("SELECT COUNT(*) FROM processes")
      end
      refute File.exist?(RetainedLogging::ProcessOwner.path(path, abandoned.id))
      assert File.exist?(RetainedLogging::ProcessOwner.path(path, live.id))
      # The recreated store immediately accepts records and serves reads.
      id = history.start_process(component: "web", at: now).fetch("process_id")
      event = history.event(at: now, category: "warnings", message: "Import failed for /srv/one.mkv")
      assert_equal "ok", history.append(process_id: id, events: [ event ], at: now)["outcome"]
      result = RetainedLogging::RetainedLogs.new(history: history, now: now + 1).call("lookback_minutes" => 1)
      assert_equal [ "Import failed for /srv/one.mkv" ], result["summaries"].map { |group| group["sample"] }
      # A store already at the current version keeps its records.
      assert_equal "ok", history.prepare["outcome"]
      assert_equal 1, RetainedLogging::RetainedLogs.new(history: history, now: now + 1).call("lookback_minutes" => 1)["total_groups"]
    ensure
      live&.close
    end
  end

  def test_a_full_page_of_maximum_samples_is_returned_rather_than_refused
    Dir.mktmpdir do |directory|
      path = File.join(directory, "history.sqlite3")
      history = RetainedLogging::History.new(path: path, scope: "test", key: "k" * 32)
      assert_equal "ok", history.prepare["outcome"]
      now = Time.utc(2026, 9, 11, 12)
      id = history.start_process(component: "web", at: now).fetch("process_id")
      # Worst case escaping: a control character costs six response bytes each.
      events = 100.times.map do |index|
        history.event(at: now, category: "warnings",
          message: "condition #{index.to_s(26).tr('0-9a-p', 'a-z')} #{"\u0001" * 480}")
      end
      assert events.all? { |event| event["sample"].bytesize > 480 }
      assert_equal "ok", history.append(process_id: id, events: events, at: now)["outcome"]
      result = RetainedLogging::RetainedLogs.new(history: history, now: now + 1).call("lookback_minutes" => 1, "limit" => 100)
      assert_equal 100, result["total_groups"]
      assert_equal 100, result["summaries"].size
      refute result["truncated"]
      assert result["summaries"].all? { |group| group["sample"].valid_encoding? && group["sample"].start_with?("condition ") }
      # Each sample is shortened to a valid prefix rather than failing the page.
      assert result["summaries"].all? { |group| events.any? { |event| event["sample"].start_with?(group["sample"]) } }
      assert result["summaries"].all? { |group| events.none? { |event| event["sample"] == group["sample"] } }
      assert_operator JSON.generate(result).bytesize, :<, RetainedLogging::History::READ_RESPONSE_BYTES
    end
  end

  def sample_rows(path)
    SQLite3::Database.new(path, readonly: true) { |db| return db.execute("SELECT scope, pattern, sample FROM patterns") }
  end

  def test_built_package_runs_storage_worker_and_summary_without_host_boot_or_paths
    root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(root, "retained_logging.gemspec"))
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "retained_logging.gem")
      capture_io { Dir.chdir(root) { Gem::Package.build(spec, false, false, archive) } }
      extracted = File.join(directory, "package")
      Gem::Package.new(archive).extract_files(extracted)
      program = <<~'PROGRAM'
        require "retained_logging"
        abort "host loaded" if defined?(Rails) || defined?(ProductionInspection) || defined?(ActiveRecord)
        File.write("host_boot.rb", 'File.write("host_booted", "yes"); abort "host preload executed"')
        ENV["RUBYOPT"] = "-r#{File.expand_path('host_boot.rb')}"
        history = RetainedLogging::History.new(path: "history.sqlite3", scope: "standalone", key: "k" * 32)
        abort "preparation failed" unless history.prepare["outcome"] == "ok"
        now = Time.now.utc
        id = history.start_process(component: "web", at: now).fetch("process_id")
        event = history.event(at: now, category: "warnings", message: "safe test")
        abort "append failed" unless history.append(process_id: id, events: [event], at: now)["outcome"] == "ok"
        result = RetainedLogging::RetainedLogs.new(history: history, now: now + 1).call({})
        abort "summary failed" unless result["total_groups"] == 1
        abort "cleanup failed" unless history.cleanup["outcome"] == "ok"
        abort "worker loaded host" if File.exist?("host_booted")
      PROGRAM
      output, errors, status = Open3.capture3({ "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil }, RbConfig.ruby,
        "-I", File.join(extracted, "lib"), "-e", program, chdir: directory)
      assert status.success?, errors
      assert_empty output
      assert_empty errors
    end
  end
end
