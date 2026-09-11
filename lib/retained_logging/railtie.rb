require "rails/railtie"
require_relative "rails_integration"

module RetainedLogging
  class Railtie < Rails::Railtie
    config.retained_logging = ActiveSupport::OrderedOptions.new
    config.retained_logging.enabled = false

    initializer "retained_logging.logger", after: :initialize_logger do |app|
      integration = RetainedLogging.rails_integration = RailsIntegration.new(app.config.retained_logging)
      if integration.enabled?
        # Run before framework subscribers share Rails.logger.
        Rails.logger = BroadcastLogger.new(Rails.logger) unless Rails.logger.is_a?(BroadcastLogger)
        app.config.logger = Rails.logger
      end
    end

    initializer "retained_logging.capture", after: :load_config_initializers do |app|
      # Register after ActiveSupport's configuration callbacks. Deriving a key
      # earlier can cache Rails' generator before its digest is configured.
      app.config.after_initialize do
        integration = RetainedLogging.rails_integration
        integration.install_lifecycle_hooks
        integration.start
      end
    end

    rake_tasks do
      load File.expand_path("tasks.rake", __dir__)
    end
  end
end
