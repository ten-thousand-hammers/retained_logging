require_relative "history"
require_relative "broadcast_logger"

module RetainedLogging
  # Collect safe metadata independently of application output and transactions.
  class Capture
    INTERVAL = 10
    MAX_INTERVAL = 30

    # Installation returns the logger that callers must retain.
    def self.install(logger, collector)
      broadcast = logger.is_a?(BroadcastLogger) ? logger : BroadcastLogger.new(logger)
      broadcast.collector = collector
      collector.observe_sources(broadcast.outputs)
      collector.unsupported_source if broadcast.outputs.empty? || broadcast.outputs.any? { |output| !output.is_a?(Logger) }
      broadcast
    end

    def initialize(history:, component:, clock: -> { Time.now }, background: true)
      raise ArgumentError, "invalid capture component" unless %w[web job].include?(component)
      @history, @component, @clock, @background = history, component, clock, background
      reset_process
    end

    def start(at: @clock.call)
      reset_process if @pid != Process.pid || @stopped
      guarded { ensure_process(at) }
      if @background && !@thread&.alive?
        @thread = Thread.new do
          loop do
            sleep INTERVAL
            break if @stopped || Thread.current != @thread
            checkpoint
          end
        end
      end
      self
    end

    def observe_sources(sources)
      @sources = ((@sources || []) + sources).uniq
    end

    def unsupported_source
      @source_unsupported = true
    end

    def interrupt
      @failures += 1
    end

    def record(severity, at, message)
      start(at: at.is_a?(Time) ? at : @clock.call) if @pid != Process.pid
      return if @stopped
      now = @clock.call
      message = message.message if message.is_a?(Exception)
      unless at.is_a?(Time) && at <= now && message.is_a?(String) && message.valid_encoding? && message.bytesize <= 65_536
        count(:unsupported)
        return
      end
      # A completed failed request is one signal, even when logged at ERROR.
      status = message.match(/\ACompleted ([45]\d{2})(?:\s|\z)/)&.captures&.first&.to_i
      category = if status
        "failed_requests"
      elsif %w[ERROR FATAL].include?(severity)
        "errors"
      elsif %w[WARN WARNING].include?(severity)
        "warnings"
      elsif %w[DEBUG INFO].include?(severity)
        count(:informational)
        return
      else
        count(:unsupported)
        return
      end
      guarded do
        next unless ensure_process(at)
        if at < @since
          interrupt
          next
        end
        event = @history.event(at: at, category: category, status: status,
          message: message, label: status ? "failed_request" : nil)
        interrupt unless event && ok?(@history.append(process_id: @process_id, events: [ event ], at: now))
      end
    end

    def checkpoint
      start if @pid != Process.pid
      guarded { checkpoint_locked(@clock.call) unless @stopped }
    end

    def stop
      return if @pid != Process.pid
      guarded do
        next if @stopped
        now = @clock.call
        if checkpoint_locked(now)
          @history.finish_process(process_id: @process_id, at: now)
        end
      end
      @stopped = true
    end

    private

    def reset_process
      @pid = Process.pid
      @mutex = Mutex.new
      @counts_mutex = Mutex.new
      @process_id = @abandoned_process_id = @thread = nil
      @failures = @acknowledged_failures = @informational = @unsupported = 0
      @stopped = false
    end

    # Never queue application threads behind a slow history write. A skipped write
    # invalidates the interval, and its message is neither buffered nor logged.
    def guarded
      mutex = @mutex
      unless mutex.try_lock
        interrupt
        return false
      end
      begin
        yield
      rescue StandardError
        interrupt
        false
      ensure
        mutex.unlock
      end
    end

    def ensure_process(now)
      return true if @process_id
      if @abandoned_process_id
        return false unless ok?(@history.finish_process(process_id: @abandoned_process_id, at: now))
        @abandoned_process_id = nil
      end
      result = @history.start_process(component: @component, at: now)
      return false unless ok?(result)
      @process_id = result.fetch("process_id")
      @since = now
      true
    end

    def checkpoint_locked(now)
      return false unless ensure_process(now)
      failures = @failures
      captured = !@source_unsupported && (@sources || []).all?(&:info?) && failures == @acknowledged_failures && now >= @since && now - @since <= MAX_INTERVAL
      if now < @since
        @abandoned_process_id, @process_id = @process_id, nil
        return false
      end
      informational, unsupported = @counts_mutex.synchronize do
        counts = [ @informational, @unsupported ]
        @informational = @unsupported = 0
        counts
      end
      checkpoint = { "starts_at" => micros(@since), "ends_at" => micros(now),
        "outcome" => captured ? "captured" : "gap", "informational_count" => informational,
        "unsupported_count" => unsupported }
      if ok?(@history.append(process_id: @process_id, checkpoint: checkpoint, at: now))
        @since = now
        @acknowledged_failures = failures
        true
      else
        # A timeout may have committed. Do not retry an overlapping checkpoint or
        # certify the old process tail. Recovery closes only this collector's
        # abandoned lifecycle before starting a fresh one, preserving the outage.
        @abandoned_process_id, @process_id = @process_id, nil
        interrupt
        false
      end
    end

    # This short lock never covers IO. Normal informational traffic must not
    # create gaps merely because a durable checkpoint is being written.
    def count(kind)
      @counts_mutex.synchronize do
        if kind == :informational
          @informational = [ @informational + 1, 2**31 - 1 ].min
        else
          @unsupported = [ @unsupported + 1, 2**31 - 1 ].min
        end
      end
    end

    def micros(time)
      (time.to_r * 1_000_000).to_i
    end

    def ok?(result)
      result["outcome"] == "ok"
    end
  end
end
