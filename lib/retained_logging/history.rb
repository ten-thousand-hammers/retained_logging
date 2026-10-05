require "json"
require "openssl"
require "securerandom"
require "active_support/message_verifier"
require "active_support/core_ext/hash/keys"
require_relative "category_names"
require_relative "storing"

module RetainedLogging
  # Internal persistence API, never an MCP argument surface. It validates every
  # value before the store sees it and reports fixed outcomes instead of raising.
  class History
    RETENTION_SECONDS = 48 * 60 * 60
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
    # Errors that mean another writer or a busy store got in the way. SQLite
    # reports a busy store as a statement timeout; Postgres reports its own
    # statement_timeout as a cancelled query.
    CONTENTION = [ "ActiveRecord::StatementTimeout", "ActiveRecord::LockWaitTimeout",
      "ActiveRecord::TransactionRollbackError", "ActiveRecord::ConnectionTimeoutError",
      "ActiveRecord::RecordNotUnique" ].freeze
    TIMEOUT = [ "ActiveRecord::QueryCanceled" ].freeze

    def initialize(scope:, key:)
      @key = key if key.is_a?(String) && key.bytesize.between?(32, 256)
      @scope = fingerprint("scope", scope) if @key && scope.is_a?(String) && scope.bytesize.between?(1, 256)
    end

    def start_process(component:, at: Time.now, id: SecureRandom.uuid)
      return failure unless @scope && %w[web job].include?(component) && timestamp(at) && valid_id?(id)
      execute(:start, id: id, scope: @scope, component: component, at: timestamp(at))
    end

    # Normalized text is fingerprinted here, and the original text accompanies it
    # as a bounded sample so a reported group can be read. A fixed label carries
    # no sample: its wording is already the label.
    def event(at:, category:, message: nil, label: nil, status: nil)
      return unless timestamp(at) && [ "errors", "warnings", CategoryNames::FAILED_REQUESTS_STORED ].include?(category)
      return unless status.nil? || (status.is_a?(Integer) && (400..599).cover?(status))
      return unless (category == CategoryNames::FAILED_REQUESTS_STORED) == !status.nil?
      pattern, sample = if label && LABELS.include?(label)
        [ "label:v1:#{label}", nil ]
      elsif label.nil? && @key && message.is_a?(String) && message.valid_encoding? && message.bytesize <= 65_536
        text = utf8(message)
        [ fingerprint("pattern", normalize(text)), clip(text, SAMPLE_BYTES) ]
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
      execute(:append, id: process_id, scope: @scope, events: events, checkpoint: checkpoint, at: timestamp(at))
    end

    def finish_process(process_id:, at: Time.now)
      return failure unless valid_id?(process_id) && timestamp(at)
      execute(:finish, id: process_id, scope: @scope, at: timestamp(at))
    end

    # Closes lifecycles that stopped writing, then expires history in bounded batches.
    def cleanup(at: Time.now)
      return failure unless @scope && timestamp(at)
      execute(:cleanup, scope: @scope, at: timestamp(at),
        cutoff: timestamp(at) - RETENTION_SECONDS * 1_000_000, limit: CLEANUP_BATCH_SIZE)
    end

    # Only RetainedLogs supplies this internal query; no client-controlled path or SQL.
    def summarize(snapshot)
      return failure unless @scope && @key
      result = execute(:summarize, scope: @scope, snapshot: snapshot)
      # A page must fit the reader's response budget, or it is not returned at all.
      return { "outcome" => "unavailable" } if JSON.generate(result).bytesize > READ_RESPONSE_BYTES
      result
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

    # Storage and every response are UTF-8, so text in another encoding converts
    # before it is normalized or sampled: the same characters must fingerprint as
    # one group whichever encoding the emitting logger handed over. The caller's
    # size limit applies to the text it supplied, ahead of this conversion.
    def utf8(text)
      return text if text.encoding == Encoding::UTF_8
      text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # A fixed byte bound can split a multi-byte character, and an invalid string
    # would fail JSON generation for a whole page, so the partial tail goes.
    def clip(text, bytes)
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
      return false unless valid_time?(value["occurred_at"]) && [ "errors", "warnings", CategoryNames::FAILED_REQUESTS_STORED ].include?(value["category"])
      status = value["status"]
      return false unless value["category"] == CategoryNames::FAILED_REQUESTS_STORED ? status.is_a?(Integer) && (400..599).cover?(status) : status.nil?
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

    # Anything the store logs while it runs belongs to the gem, not the
    # application, so capture skips it rather than recording itself.
    def execute(operation, **arguments)
      RetainedLogging.storing do
        require_relative "store"
        Record.connection_pool.with_connection do
          Record.uncached { Store.public_send(operation, **arguments) }.deep_stringify_keys
        end
      end
    rescue StandardError => error
      ancestors = error.class.ancestors.map(&:name)
      outcome = if (ancestors & TIMEOUT).any? then "timeout"
      elsif (ancestors & CONTENTION).any? then "contention"
      else "unavailable"
      end
      { "outcome" => outcome }
    end
  end
end
