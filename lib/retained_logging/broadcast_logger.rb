require "active_support/logger"
require "active_support/broadcast_logger"
require_relative "storing"

module RetainedLogging
  # Public BroadcastLogger integration. Original destinations retain their
  # formatters and devices; the metadata destination never formats raw text.
  class BroadcastLogger < ActiveSupport::BroadcastLogger
    class Sink < ActiveSupport::Logger
      attr_accessor :collector

      def initialize(outputs)
        super(nil)
        @outputs = outputs
      end

      def level
        @outputs.map(&:level).min || Logger::UNKNOWN
      end

      def add(severity, message = nil, progname = nil)
        severity ||= Logger::UNKNOWN
        return true if RetainedLogging.storing?
        collector&.interrupt if level > Logger::INFO
        return true if severity < level || !collector
        if message.nil?
          message = block_given? ? yield : (progname || @outputs.first&.progname)
        end
        begin
          collector.record(Logger::SEV_LABEL[severity] || "UNKNOWN", Time.now, message)
        rescue StandardError
          collector.interrupt
        end
        true
      end
      alias_method :log, :add

      def <<(_message)
        collector&.unsupported_source
        self
      end
    end

    attr_reader :outputs, :collector

    def initialize(*loggers, collector: nil)
      @outputs = loggers.flat_map { |logger| self.class.output_loggers(logger) }.uniq
      @capture_sink = Sink.new(@outputs)
      super(@capture_sink, *@outputs)
      self.collector = collector
    end

    def formatter
      outputs.first&.formatter
    end

    def local_level
      outputs.find { |logger| logger.respond_to?(:local_level) }&.local_level
    end

    def <<(message)
      @capture_sink << message
      outputs.map { |logger| logger << message }.first
    end

    def self.output_loggers(logger)
      if logger.is_a?(ActiveSupport::BroadcastLogger)
        logger.broadcasts.flat_map { |sink| output_loggers(sink) }
      elsif logger.is_a?(Sink)
        []
      else
        [ logger ]
      end
    end

    def collector=(collector)
      @collector = @capture_sink.collector = collector
    end

    # BroadcastLogger delegates unknown methods to destinations. TaggedLogging's
    # block yields its original logger, so explicitly keep the broadcast in use.
    def tagged(*tags, &block)
      if block
        with_tags(outputs.select { |logger| logger.respond_to?(:tagged) }, tags) { block.call(self) }
      else
        self.class.new(*outputs.map { |logger| logger.respond_to?(:tagged) ? logger.tagged(*tags) : logger }, collector: collector)
      end
    end

    private

    def with_tags(loggers, tags, &block)
      return block.call if loggers.empty?
      loggers.first.tagged(*tags) { with_tags(loggers.drop(1), tags, &block) }
    end
  end
end
