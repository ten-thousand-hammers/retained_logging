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
      refute_includes result.to_s, "sentinel"
      refute_includes File.binread(path), "sentinel"
      assert_includes @output.string, "failed write"
      assert_equal "ok", reopened.cleanup(at: now)["outcome"]
    end
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
