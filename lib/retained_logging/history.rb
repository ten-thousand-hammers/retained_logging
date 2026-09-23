require "json"
require "openssl"
require "securerandom"
require "open3"
require "active_support/message_verifier"
require_relative "process_owner"

module RetainedLogging
  # Internal persistence API, never an MCP argument surface. No Rails connections or logger.
  class History
    RETENTION_SECONDS = 48 * 60 * 60
    BUDGET_SECONDS = 1
    PREPARE_BUDGET_SECONDS = 10
    READ_BUDGET_SECONDS = 8
    READ_RESPONSE_BYTES = 240 * 1024
    BATCH_SIZE = 100
    CLEANUP_BATCH_SIZE = 1000
    SAMPLE_BYTES = 512
    LABELS = %w[application_error application_warning failed_request].freeze
    # Occurrence-specific text splits one condition across many identifiers, so a fixed
    # set of variable classes collapses before the message is fingerprinted. Every branch
    # is atomic and every quantifier is bounded by one token, so matching is a single
    # left-to-right pass that cannot backtrack into a variable run, over text the caller
    # has already capped at 64 KiB. A path component accepts any word character so a
    # non-ASCII filename collapses whole, and a quoted path may hold spaces; the quotes
    # themselves stay outside the match so surrounding wording keeps its shape. A digits-only
    # run is a number at every length, so only a run carrying a hexadecimal letter is a hex run.
    VARIABLE_TEXT = /
      (?<uuid>\b\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\b)
      | (?<duration>\b(?>\d+)(?:\.(?>\d+))?[ ]?(?:ms|ns|us|millisecond|second|minute|hour|day|s|m|h)s?\b)
      | (?<path>
          (?<=")(?>\/[^"\n]*+)(?=")
          | (?<=')(?>\/[^'\n]*+)(?=')
          | (?<![[:word:]])(?>(?:\/[[:word:].+@%~-]+)+)\/?
        )
      | (?<hex>\b(?:0x(?>\h+)|(?!(?>\d+)\b)(?>\h{8,}))\b)
      | (?<number>\b(?>\d+)(?:\.(?>\d+))?\b)
    /x
    OUTCOMES = %w[ok invalid_input unavailable contention capacity timeout].freeze
    WORKER_LOAD_PATH = %w[sqlite3 json time date].flat_map do |name|
      Gem::Specification.find_by_name(name).full_require_paths
    end.join(File::PATH_SEPARATOR).freeze

    def initialize(path:, scope:, key:)
      @path = path.to_s
      @key = key if key.is_a?(String) && key.bytesize.between?(32, 256)
      @scope = fingerprint("scope", scope) if @key && scope.is_a?(String) && scope.bytesize.between?(1, 256)
    end

    def prepare
      execute("prepare")
    end

    def acquire_owner
      ProcessOwner.new(@path, SecureRandom.uuid)
    end

    def start_process(component:, at: Time.now, owner: nil)
      return failure unless @scope && %w[web job].include?(component) && timestamp(at)
      id = owner ? owner.id : SecureRandom.uuid
      execute("start", id: id, scope: @scope, component: component, at: timestamp(at))
    end

    # Normalized text is fingerprinted here, and the original text accompanies it
    # as a bounded sample so a reported group can be read. A fixed label carries
    # no sample: its wording is already the label.
    def event(at:, category:, message: nil, label: nil, status: nil)
      return unless timestamp(at) && %w[errors warnings failed_requests].include?(category)
      return unless status.nil? || (status.is_a?(Integer) && (400..599).cover?(status))
      return unless (category == "failed_requests") == !status.nil?
      pattern, sample = if label && LABELS.include?(label)
        [ "label:v1:#{label}", nil ]
      elsif label.nil? && @key && message.is_a?(String) && message.valid_encoding? && message.bytesize <= 65_536
        [ fingerprint("pattern", normalize(message)), clip(message, SAMPLE_BYTES) ]
      end
      return unless pattern
      { "occurred_at" => timestamp(at), "category" => category, "status" => status,
        "pattern" => pattern, "sample" => sample }
    end

    # A checkpoint certifies only its explicit interval. Gaps are never filled by storage.
    # Events and the checkpoint commit together, or neither commits.
    def append(process_id:, events: [], checkpoint: nil, at: Time.now)
      return failure unless valid_id?(process_id) && timestamp(at) && events.is_a?(Array) && events.size <= BATCH_SIZE
      return failure unless events.all? { |item| valid_event?(item) }
      return failure unless checkpoint.nil? || valid_checkpoint?(checkpoint)
      execute("append", id: process_id, scope: @scope, events: events, checkpoint: checkpoint, at: timestamp(at))
    end

    def finish_process(process_id:, at: Time.now)
      return failure unless valid_id?(process_id) && timestamp(at)
      execute("finish", id: process_id, scope: @scope, at: timestamp(at))
    end

    # Operator-supplied upper bound after independently confirming owner exit.
    # Needed for legacy records that predate the process ownership lock.
    def reconcile_process(process_id:, stopped_at:, at: Time.now)
      return failure unless valid_id?(process_id) && timestamp(stopped_at) && timestamp(at) && stopped_at <= at
      execute("reconcile", id: process_id, scope: @scope, at: timestamp(stopped_at))
    end

    def cleanup(at: nil)
      clock = Time.now
      at ||= clock
      return failure unless timestamp(at)
      execute("cleanup", scope: @scope, at: timestamp(at), clock_offset: timestamp(at) - timestamp(clock),
        cutoff: timestamp(at) - RETENTION_SECONDS * 1_000_000, limit: CLEANUP_BATCH_SIZE)
    end

    # Only RetainedLogs supplies this internal query; no client-controlled path or SQL.
    def summarize(snapshot)
      return failure unless @scope && @key
      execute("summarize", scope: @scope, snapshot: snapshot)
    end

    def encode_cursor(snapshot)
      cursor_verifier.generate(snapshot.merge("scope" => @scope))
    end

    def decode_cursor(token)
      return unless @scope && @key
      value = cursor_verifier.verified(token)
      value if value.is_a?(Hash) && value["scope"] == @scope
    rescue StandardError
      nil
    end

    private

    def cursor_verifier
      ActiveSupport::MessageVerifier.new(fingerprint("cursor", "retained-logs-v1"), digest: "SHA256", serializer: JSON)
    end

    def failure
      { "outcome" => "invalid_input" }
    end

    def timestamp(value)
      (value.to_r * 1_000_000).to_i if value.is_a?(Time) && value.to_i.between?(0, 32_503_680_000)
    end

    # Occurrences of one condition differ only in their variable text, so two messages
    # group together exactly when the wording around that text is identical.
    def normalize(message)
      message.gsub(VARIABLE_TEXT) { "<#{Regexp.last_match.named_captures.compact.keys.first}>" }
    end

    # A fixed byte bound can split a multi-byte character, and an invalid string
    # would fail JSON generation for a whole page, so the partial tail goes.
    # Storage and every response are UTF-8, so another encoding converts first.
    def clip(text, bytes)
      text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless text.encoding == Encoding::UTF_8
      text = text.byteslice(0, bytes)
      text = text.byteslice(0, text.bytesize - 1) until text.empty? || text.valid_encoding?
      text
    end

    def fingerprint(kind, value)
      "hmac:v1:#{OpenSSL::HMAC.hexdigest('SHA256', @key, "#{kind}\0#{value}")}"
    end

    def valid_id?(value)
      @scope && value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    def valid_time?(value)
      value.is_a?(Integer) && value.between?(0, 32_503_680_000_000_000)
    end

    def valid_event?(value)
      return false unless value.is_a?(Hash) && value.keys.sort == %w[category occurred_at pattern sample status]
      return false unless valid_time?(value["occurred_at"]) && %w[errors warnings failed_requests].include?(value["category"])
      status = value["status"]
      return false unless value["category"] == "failed_requests" ? status.is_a?(Integer) && (400..599).cover?(status) : status.nil?
      pattern, sample = value.values_at("pattern", "sample")
      return false unless pattern.is_a?(String)
      # Nothing unbounded reaches the worker: a fingerprinted group carries one
      # bounded sample, and a fixed label carries none.
      if LABELS.any? { |label| pattern == "label:v1:#{label}" }
        sample.nil?
      else
        pattern.match?(/\Ahmac:v1:[0-9a-f]{64}\z/) && sample.is_a?(String) &&
          sample.encoding == Encoding::UTF_8 && sample.valid_encoding? && sample.bytesize <= SAMPLE_BYTES
      end
    end

    def valid_checkpoint?(value)
      value.is_a?(Hash) && value.keys.sort == %w[ends_at informational_count outcome starts_at unsupported_count] &&
        valid_time?(value["starts_at"]) && valid_time?(value["ends_at"]) && value["ends_at"] >= value["starts_at"] &&
        %w[captured gap].include?(value["outcome"]) && %w[informational_count unsupported_count].all? { |k| value[k].is_a?(Integer) && value[k].between?(0, 2**31 - 1) }
    end

    def execute(operation, **arguments)
      read = operation == "summarize"
      # Explicit schema creation/migration is maintenance, outside capture and MCP.
      budget = case operation
      when "prepare" then PREPARE_BUDGET_SECONDS
      when "summarize" then READ_BUDGET_SECONDS
      else BUDGET_SECONDS
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
      # Isolate SQLite's GVL-holding calls so cancellation cannot harm the host.
      # Use the host-selected dependency versions without booting its whole bundle
      # on every write. Inherited Ruby preloads must not run inside this worker.
      input, output, waiter = Open3.popen2({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby,
        "--disable-gems", "-I", WORKER_LOAD_PATH, File.expand_path("history_worker.rb", __dir__), err: File::NULL)
      pending = JSON.generate(arguments.merge(operation: operation, database: @path))
      until pending.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return { "outcome" => "timeout" } unless remaining.positive? && IO.select(nil, [ input ], nil, remaining)
        written = input.write_nonblock(pending, exception: false)
        pending = pending.byteslice(written..) unless written == :wait_writable
      end
      input.close
      raw = +""
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return { "outcome" => "timeout" } unless remaining.positive? && IO.select([ output ], nil, nil, remaining)
        chunk = output.read_nonblock(1024, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable
        raw << chunk
        return { "outcome" => "unavailable" } if raw.bytesize > (read ? READ_RESPONSE_BYTES : 1024)
      end
      result = JSON.parse(raw)
      OUTCOMES.include?(result["outcome"]) ? result : { "outcome" => "unavailable" }
    rescue StandardError
      { "outcome" => "unavailable" }
    ensure
      if waiter
        begin
          Process.kill("KILL", waiter.pid) if waiter.alive?
        rescue Errno::ESRCH
          # Worker exited between checking and cancellation.
        end
        waiter.join
      end
      [ input, output ].compact.each { |io| io.close unless io.closed? }
    end
  end
end
