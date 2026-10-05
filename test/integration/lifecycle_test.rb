require "minitest/autorun"
require "active_support"
require "active_support/test_case"
require "active_support/key_generator"
require "retained_logging"
require "sqlite3"
require "tmpdir"
require "timeout"
require "net/http"
require "retained_logging/history_worker"

# Boots a disposable Rails app in child processes to exercise the Railtie, Puma plugin
# and Solid Queue hooks against real servers and workers.
class RetainedLoggingLifecycleTest < ActiveSupport::TestCase
  FIXTURE = File.expand_path("../fixtures/lifecycle_app.rb", __dir__)

  setup do
    @directory = Dir.mktmpdir("retained-lifecycle")
    FileUtils.mkdir_p(File.join(@directory, "config"))
    File.write(File.join(@directory, "config/database.yml"), { "test" => {
      "adapter" => "sqlite3", "database" => File.join(@directory, "queue.sqlite3"), "pool" => 5, "timeout" => 1000
    } }.to_yaml)
    key = ActiveSupport::KeyGenerator.new("lifecycle-test-secret" * 4, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA256)
      .generate_key("retained_logging/lifecycle/v1", 32)
    @history = RetainedLogging::History.new(path: File.join(@directory, "history.sqlite3"), scope: "lifecycle", key: key)
    assert_equal "ok", @history.prepare["outcome"]
    @pids = []
  end

  teardown do
    @pids.each do |pid|
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
    @pids.each do |pid|
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
    FileUtils.remove_entry(@directory)
  end

  test "real Rails boot installs shared capture once and keeps final exit logging" do
    pid = launch("boot")
    finish(pid)
    assert_equal 1, rows("processes").size
    { "rails event" => "errors", "active job event" => "warnings", "queue event" => "warnings",
      "last application event" => "errors", "exit handler registered before initialization" => "errors" }.each do |message, category|
      pattern = @history.event(at: Time.now, category: category, message: message).fetch("pattern")
      assert_equal 1, rows("events").count { |row| row["pattern"] == pattern }
    end
    assert rows("processes").all? { |row| row["ended_at"] }
    assert rows("checkpoints").all? { |row| row["outcome"] == "captured" }
    refute_includes rows("events").to_json, "last application event"
    assert_includes output, "last application event"
  end

  test "disabled collection and invalid attribution leave ordinary logging operational" do
    [ { "LIFECYCLE_ENABLED" => "false" }, { "LIFECYCLE_COMPONENT" => "invalid" } ].each do |env|
      finish(launch("boot", env))
      assert_empty rows("processes")
      assert_empty rows("events")
      assert_includes output, "rails event"
    end
  end

  test "unavailable history does not prevent Rails boot or stdout logging" do
    File.unlink(File.join(@directory, "history.sqlite3"))
    finish(launch("boot"))
    assert_includes output, "rails event"
    assert_includes output, "last application event"
    refute_includes output, "SQLite3::"
  end

  test "a store left at another schema version does not prevent Rails boot or stdout logging" do
    SQLite3::Database.new(File.join(@directory, "history.sqlite3")) { |db| db.execute("PRAGMA user_version = 2") }
    finish(launch("boot"))
    assert_empty rows("processes")
    assert_includes output, "rails event"
    assert_includes output, "last application event"
    refute_includes output, "SQLite3::"
  end

  test "gem task prepares history while collection is disabled and cleanup remains available" do
    File.unlink(File.join(@directory, "history.sqlite3"))
    finish(launch("prepare", "LIFECYCLE_ENABLED" => "false"))
    assert_includes output, "Retained logging prepared"
    assert_empty rows("processes")
    SQLite3::Database.new(File.join(@directory, "history.sqlite3"), readonly: true) do |db|
      assert_equal RetainedLogging::HistoryWorker::SCHEMA_VERSION, db.get_first_value("PRAGMA user_version")
    end
  end

  test "operator task closes a legacy lifecycle without inventing checkpoints" do
    finish(launch("reconcile", "LIFECYCLE_ENABLED" => "false"))
    refute_nil rows("processes").sole["ended_at"]
    assert_empty rows("checkpoints")
    assert_includes output, "Retained lifecycle closed; its unobserved interval remains a gap"
  end

  test "verify task exits cleanly for live capture and fails for a component that stopped" do
    finish(launch("verify", "LIFECYCLE_ENABLED" => "false", "LIFECYCLE_VERIFY_COMPONENTS" => "web,job"))
    assert_match(/web: ok; 100\.0% covered/, output)
    assert_match(/job: ok; 100\.0% covered/, output)

    FileUtils.rm_rf(Dir.glob(File.join(@directory, "history.sqlite3*")))
    assert_equal "ok", @history.prepare["outcome"]
    _, status = Timeout.timeout(30) do
      Process.wait2(launch("verify", "LIFECYCLE_ENABLED" => "false", "LIFECYCLE_VERIFY_COMPONENTS" => "web"))
    end
    refute status.success?, output
    assert_match(/web: ok/, output)
    assert_match(/job: FAILED \(nothing_captured, not_checkpointing\); 0\.0% covered/, output)
    assert_includes output, "Retained logging verification failed"
  end

  test "worker drain timeout records a gap without changing job shutdown" do
    pid = launch("timeout")
    wait_for("started")
    Process.kill("TERM", File.read(File.join(@directory, "started")).to_i)
    finish(pid)
    refute File.exist?(File.join(@directory, "finished"))
    assert rows("checkpoints").any? { |row| row["outcome"] == "gap" }
    assert rows("processes").all? { |row| row["ended_at"] }
  end

  %w[worker async].each do |mode|
    test "#{mode} captures the job draining after stop and post-shutdown callbacks" do
      pid = launch(mode)
      wait_for("started")
      assert_equal "true", File.read(File.join(@directory, "collector_thread"))
      if mode == "worker"
        Process.kill("TERM", File.read(File.join(@directory, "started")).to_i)
      else
        touch("stop")
      end
      wait_for("stopping")
      touch("release")
      finish(pid)
      assert File.exist?(File.join(@directory, "finished"))
      expected = mode == "worker" ? 2 : 1
      assert_equal expected, rows("processes").size
      assert rows("processes").all? { |row| row["ended_at"] }
      patterns = rows("events").map { |row| row["pattern"] }
      [ "final draining job event", "worker exit event", "last application event" ].each do |message|
        assert_includes patterns, @history.event(at: Time.now, category: "errors", message: message).fetch("pattern")
      end
      assert_includes output, "final draining job event"
    end
  end

  test "a polling worker certifies every checkpoint after performing a job" do
    pid = launch("polling", "LIFECYCLE_SILENCE_POLLING" => "false")
    wait_for("performed")
    touch("stop")
    finish(pid)
    refute_empty rows("checkpoints")
    assert_equal [ "captured" ], rows("checkpoints").map { |row| row["outcome"] }.uniq
  end

  test "hard worker exit leaves an unfinished lifecycle instead of a complete tail" do
    pid = launch("hard_exit")
    wait_for("started")
    Process.kill("KILL", File.read(File.join(@directory, "started")).to_i)
    finish(pid)
    assert_equal 2, rows("processes").size
    assert_equal 1, rows("processes").count { |row| row["ended_at"].nil? }
    observed_at = Time.now
    result = @history.cleanup(at: observed_at)
    assert_equal "ok", result["outcome"]
    assert_equal 1, result["processes_reconciled"]
    assert rows("processes").all? { |row| row["ended_at"] }
    coverage = RetainedLogging::RetainedLogs.new(history: @history, now: observed_at).call("component" => "job")["coverage"].sole
    assert_equal "partial", coverage["availability"]
    assert_includes coverage["reasons"], "interrupted_capture"
    refute_includes coverage["reasons"], "unfinalized_tail"
  end

  [ [ 0, false ], [ 1, false ], [ 1, true ] ].each do |workers, preload|
    test "Puma plugin captures draining requests with workers=#{workers} preload=#{preload}" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      File.write(File.join(@directory, "config.ru"), "require #{FIXTURE.inspect}\nrun Rails.application\n")
      File.write(File.join(@directory, "puma.rb"), <<~CONFIG)
        bind "tcp://127.0.0.1:#{port}"
        raise_exception_on_sigterm false
        workers #{workers}
        threads 1, 1
        #{preload ? 'preload_app!' : ''}
        plugin :retained_logging
        rackup #{File.join(@directory, 'config.ru').inspect}
      CONFIG
      pid = launch("puma", {}, "-S", "puma", "-C", File.join(@directory, "puma.rb"))
      Timeout.timeout(30) do
        loop do
          break if request(port, "/probe").code == "200"
        rescue Errno::ECONNREFUSED, EOFError
          sleep 0.05
        end
      end
      if preload
        previous_worker = request(port, "/probe").body
        Process.kill("USR2", pid)
        Timeout.timeout(30) do
          loop do
            probe = request(port, "/probe")
            break if probe.code == "200" && probe.body != previous_worker
            sleep 0.05
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
            sleep 0.05
          end
        end
      end
      response = Thread.new { request(port, "/drain") }
      wait_for("started")
      Process.kill("TERM", pid)
      # Puma must wait for this request before closing the worker's capture.
      touch("release")
      assert_equal "drained", response.value.body
      finish(pid)
      pattern = @history.event(at: Time.now, category: "errors", message: "final draining request event").fetch("pattern")
      assert_equal 1, rows("events").count { |row| row["pattern"] == pattern }
      assert rows("processes").all? { |row| row["ended_at"] }
    ensure
      response&.kill
    end
  end

  private

  def launch(mode, extra = {}, *command)
    env = { "RAILS_ENV" => "test", "LIFECYCLE_ROOT" => @directory,
      "LIFECYCLE_MODE" => mode, "LIFECYCLE_ENABLED" => "true", "LIFECYCLE_COMPONENT" => mode == "puma" ? "web" : "job" }.merge(extra)
    command = [ FIXTURE ] if command.empty?
    pid = Process.spawn(env, RbConfig.ruby, "-rbundler/setup", *command,
      out: File.join(@directory, "output"), err: [ :child, :out ], pgroup: true)
    @pids << pid
    pid
  end

  def finish(pid)
    _, status = Timeout.timeout(30) { Process.wait2(pid) }
    assert status.success?, output
  end

  def wait_for(name)
    Timeout.timeout(30) { sleep 0.02 until File.exist?(File.join(@directory, name)) }
  rescue Timeout::Error
    flunk "Timed out waiting for #{name}: #{output}"
  end

  def touch(name)
    File.write(File.join(@directory, name), "yes")
  end

  def rows(table)
    SQLite3::Database.new(File.join(@directory, "history.sqlite3"), readonly: true) do |db|
      db.results_as_hash = true
      return db.execute("SELECT * FROM #{table}")
    end
  end

  def output
    File.read(File.join(@directory, "output"))
  end

  def request(port, path)
    Net::HTTP.start("127.0.0.1", port, nil, open_timeout: 1, read_timeout: 30) { |http| http.get(path) }
  end
end
