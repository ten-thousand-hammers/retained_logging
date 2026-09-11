module RetainedLogging
  # Rails and process adapters share one collector per OS process. Capture resets
  # its identity, locks and checkpoint thread when inherited across a fork.
  class RailsIntegration
    attr_reader :collector

    def initialize(options)
      @options = options
    end

    def enabled?
      @options.enabled == true && %w[web job].include?(@options.component)
    end

    def history
      @options.history.call
    end

    def start
      return unless enabled?
      @collector ||= Capture.new(history: history, component: @options.component)
      wrappers = {}.compare_by_identity
      owners = [ Rails ]
      owners << ActiveJob::Base if defined?(ActiveJob::Base)
      owners << SolidQueue if defined?(SolidQueue)
      owners.each do |owner|
        logger = owner.logger
        next unless logger
        owner.logger = wrappers[logger] ||= Capture.install(logger, @collector)
      end
      @collector.start
    rescue StandardError
      # Configuration and persistence failures must not prevent application boot.
      nil
    end

    def stop
      @collector&.stop
    end

    def install_lifecycle_hooks
      return if @hooks_installed || !enabled?
      @hooks_installed = true
      return unless defined?(SolidQueue)

      SolidQueue.on_start { start }
      SolidQueue.on_exit { @collector&.checkpoint }
      %i[worker dispatcher scheduler].each do |role|
        SolidQueue.public_send("on_#{role}_start") { start }
        SolidQueue.public_send("on_#{role}_exit") do |process|
          # Workers can exceed their drain timeout. Do not certify that interval.
          @collector&.interrupt if role == :worker && !process.pool.idle?
          @collector&.checkpoint
        end
      end
      # Exit hooks follow draining, but precede final queue instrumentation. Keep
      # capture attached until Ruby exits; async roles share the same collector.
    end
  end

  class << self
    attr_accessor :rails_integration
  end

  # Register while the adapter loads, before application initializers can add
  # exit handlers. Ruby runs later registrations first, including final logging.
  at_exit { rails_integration&.stop }
end
