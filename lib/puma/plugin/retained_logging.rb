require "puma/plugin"
require "retained_logging/rails_integration"

# Puma 8 exposes configuration hooks through its plugin launcher. Ruby's at_exit
# closes workers after draining and final logging; exit! leaves an open tail.
Puma::Plugin.create do
  def start(launcher)
    launcher.config.configure do |config|
      config.before_fork { RetainedLogging.rails_integration&.stop }
      config.before_worker_boot { RetainedLogging.rails_integration&.start }
    end
    # Hot restart uses exec, which does not run at_exit handlers.
    launcher.events.before_restart { RetainedLogging.rails_integration&.stop }
  end
end
