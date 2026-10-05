require "active_support"

module RetainedLogging
  # Hosts list this in the store's database.yml entry as migrations_paths, so
  # bin/rails db:prepare creates and migrates it like any other database.
  MIGRATIONS_PATH = File.expand_path("../db/migrate", __dir__)

  autoload :Record, "retained_logging/record"
end

require_relative "retained_logging/history"
require_relative "retained_logging/capture"
require_relative "retained_logging/retained_logs"
require_relative "retained_logging/verification"
require_relative "retained_logging/railtie" if defined?(Rails::Railtie)
