require "minitest/autorun"
require "retained_logging"
require "tmpdir"
require "retained_logging/store"

# The suite runs against SQLite by default. Set RETAINED_LOGGING_TEST_POSTGRES_URL
# to a disposable Postgres database to run the same tests against Postgres. The
# name avoids <database>_DATABASE_URL, which Rails reads for named databases.
module StoreTestSupport
  DIRECTORY = Dir.mktmpdir("retained-logging-store")
  Minitest.after_run { FileUtils.remove_entry(DIRECTORY) }

  def self.config
    if (url = ENV["RETAINED_LOGGING_TEST_POSTGRES_URL"]) && !url.empty?
      { url: url }
    else
      { adapter: "sqlite3", database: File.join(DIRECTORY, "history.sqlite3") }
    end
  end

  # Migrations run on ActiveRecord::Base, as Rails runs them for any database.
  def self.prepare
    return if @prepared
    ActiveRecord::Base.establish_connection(config)
    RetainedLogging::Record.establish_connection(config)
    ActiveRecord::Migration.verbose = false
    ActiveRecord::MigrationContext.new(RetainedLogging::MIGRATIONS_PATH).migrate
    @prepared = true
  end

  # Each test starts from an empty store.
  def self.reset
    prepare
    [ RetainedLogging::Sample, RetainedLogging::Completion, RetainedLogging::Checkpoint,
      RetainedLogging::Event, RetainedLogging::Lifecycle ].each(&:delete_all)
  end
end
