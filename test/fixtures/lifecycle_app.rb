# A disposable Rails app exercises the gem's real Railtie and installed adapters.
require "bundler/setup"
require "rails/all"
require "solid_queue"
require "retained_logging"

class RetainedLoggingLifecycleApp < Rails::Application
  config.load_defaults 8.1
  config.root = ENV.fetch("LIFECYCLE_ROOT")
  config.eager_load = false
  config.secret_key_base = "lifecycle-test-secret" * 4
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = :info
  config.active_support.deprecation = :stderr
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :primary } }
  config.retained_logging.enabled = ENV.fetch("LIFECYCLE_ENABLED") == "true"
  config.retained_logging.component = ENV.fetch("LIFECYCLE_COMPONENT")
  # Hosts that capture job processes must not silence Solid Queue polling, because
  # silencing lowers the log level and the collector then rejects coverage.
  polling = ENV["LIFECYCLE_SILENCE_POLLING"].presence
  config.solid_queue.silence_polling = polling == "true" if polling
  config.retained_logging.history = -> {
    RetainedLogging::History.new(path: Rails.root.join("history.sqlite3"), scope: "lifecycle",
      key: Rails.application.key_generator.generate_key("retained_logging/lifecycle/v1", 32))
  }
end

at_exit { Rails.logger.error("exit handler registered before initialization") }
Rails.application.initialize!
integration = RetainedLogging.rails_integration
3.times do
  integration.install_lifecycle_hooks
  integration.start
end

at_exit { Rails.logger.error("last application event") }

case ENV.fetch("LIFECYCLE_MODE")
when "boot"
  Rails.logger.error("rails event")
  ActiveJob::Base.logger.warn("active job event")
  SolidQueue.logger.warn("queue event")
when "prepare"
  Rails.application.load_tasks
  Rake::Task["retained_logging:prepare"].invoke
  abort "cleanup failed" unless integration.history.cleanup.fetch("outcome") == "ok"
when "reconcile"
  Rails.application.load_tasks
  id = integration.history.start_process(component: "job", at: Time.now - 60).fetch("process_id")
  Rake::Task["retained_logging:reconcile"].invoke(id, Time.now.utc.iso8601(6))
when "verify"
  Rails.application.load_tasks
  history = integration.history
  now = Time.now
  # Ten-second captured checkpoints across the last six minutes, as healthy capture writes them.
  ENV.fetch("LIFECYCLE_VERIFY_COMPONENTS").split(",").each do |component|
    started = now - 360
    id = history.start_process(component: component, at: started).fetch("process_id")
    36.times do |step|
      from, to = started + step * 10, started + (step + 1) * 10
      checkpoint = { "starts_at" => (from.to_r * 1_000_000).to_i, "ends_at" => (to.to_r * 1_000_000).to_i,
        "outcome" => "captured", "informational_count" => 1, "unsupported_count" => 0 }
      abort "seeding failed" unless history.append(process_id: id, checkpoint: checkpoint, at: to).fetch("outcome") == "ok"
    end
  end
  Rake::Task["retained_logging:verify"].invoke("4")
when "worker", "async", "hard_exit", "timeout"
  ActiveRecord::Migration.verbose = false
  load File.expand_path("queue_schema.rb", __dir__)
  class LifecycleDrainJob < ActiveJob::Base
    def perform
      File.write(Rails.root.join("started"), Process.pid)
      sleep 0.01 until File.exist?(Rails.root.join("release"))
      logger.error("final draining job event")
      File.write(Rails.root.join("finished"), "yes")
    end
  end
  SolidQueue.shutdown_timeout = 0.01 if ENV["LIFECYCLE_MODE"] == "timeout"
  LifecycleDrainJob.perform_later
  SolidQueue.on_worker_stop do
    Rails.logger.warn("worker stop event")
    File.write(Rails.root.join("stopping"), "yes")
  end
  SolidQueue.on_worker_start do
    # Verify the fork has a live checkpoint thread even before another log call.
    thread = integration.collector.instance_variable_get(:@thread)
    File.write(Rails.root.join("collector_thread"), thread&.alive?.to_s)
  end
  SolidQueue.on_worker_exit { Rails.logger.error("worker exit event") }
  worker = SolidQueue::Worker.new(queues: [ "default" ], threads: 1, polling_interval: 0.01)
  worker.mode = ENV["LIFECYCLE_MODE"] == "async" ? :async : :fork
  pid = worker.start
  File.write(Rails.root.join("worker"), pid)
  if ENV["LIFECYCLE_MODE"] == "async"
    sleep 0.01 until File.exist?(Rails.root.join("stop"))
    worker.stop
    Rails.logger.error("supervisor still collecting")
  else
    Process.wait(pid)
  end
when "polling"
  ActiveRecord::Migration.verbose = false
  load File.expand_path("queue_schema.rb", __dir__)
  class LifecyclePollingJob < ActiveJob::Base
    def perform
      File.write(Rails.root.join("performed"), Process.pid)
    end
  end
  LifecyclePollingJob.perform_later
  worker = SolidQueue::Worker.new(queues: [ "default" ], threads: 1, polling_interval: 0.01)
  worker.mode = :async
  worker.start
  sleep 0.01 until File.exist?(Rails.root.join("stop"))
  worker.stop
when "puma"
  # Loaded by Puma's rackup path, before or after forking according to preload_app.
  Rails.application.routes.draw do
    get "/probe", to: ->(_env) { [ 200, {}, [ Process.pid.to_s ] ] }
    get "/drain", to: ->(_env) {
      File.write(Rails.root.join("started"), Process.pid)
      sleep 0.01 until File.exist?(Rails.root.join("release"))
      Rails.logger.error("final draining request event")
      [ 200, {}, [ "drained" ] ]
    }
  end
end
