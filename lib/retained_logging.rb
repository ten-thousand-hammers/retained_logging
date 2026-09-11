require "active_support"
require_relative "retained_logging/history"
require_relative "retained_logging/capture"
require_relative "retained_logging/retained_logs"
require_relative "retained_logging/railtie" if defined?(Rails::Railtie)
