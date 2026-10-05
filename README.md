# Retained logging

A gem for bounded application evidence. It retains bounded
metadata and keyed pattern identifiers in SQLite for 48 hours, with checkpoints
that distinguish captured silence from missing collection.
An identifier is a keyed fingerprint of the normalized message, and each identifier also retains one readable sample of the original message text, clipped to 512 bytes on a whole-character boundary.
The sample comes from the first message that produced the identifier and is never overwritten; cleanup deletes it once no retained occurrence carries that identifier, so it does not outlive the 48 hour window.
Anyone who can read the database file or the host's read surface can read that text, so the host controls access to both.
Nothing else is retained: URLs, parameters, credentials and stack traces have no columns of their own and reach storage only inside a captured message.

```ruby
require "retained_logging"
require "active_support/tagged_logging"

history = RetainedLogging::History.new(path: durable_path, scope: deployment_scope,
  key: derived_key) # at least 32 bytes, supplied by the host
history.prepare # explicit deployment step; check the fixed outcome before activation
collector = RetainedLogging::Capture.new(history: history, component: "web")
logger = RetainedLogging::Capture.install(stdout_logger, collector)
collector.start
logger.tagged("request-id") { |log| log.warn("application warning") }
collector.stop # graceful completion; arrange host process/fork hooks

result = RetainedLogging::RetainedLogs.new(history: history).call(
  "component" => "all", "lookback_minutes" => 1440, "limit" => 100)
```

Keep the returned logger in every caller. Installation preserves the original output
loggers and adds one metadata destination using ActiveSupport's public broadcast
API. Reinstalling the returned logger is idempotent. Tags and lazy blocks work in
both tagged forms; original output destinations keep their formatters and devices.
Use INFO or lower to capture failed requests logged at INFO. Checkpoints reject
coverage when registered sources filter INFO. A host can install a
`RetainedLogging::BroadcastLogger` before sharing its logger, then attach capture
with `Capture.install` once storage configuration is ready.

The host supplies `web`/`job` attribution, durable storage, a stable scope and key,
and scheduled `history.cleanup`. Standalone callers arrange logger assignment and
lifecycle hooks; Rails callers can use the bundled integration below.
History creation is explicit; ordinary writes and reads never prepare the schema.
Capture writes and cleanup have a one-second worker budget; reads have an
eight-second budget. Explicit schema preparation has a separate ten-second budget
for schema creation on durable storage. It never runs during capture
or an inspection request.
Checkpoint finalization serializes capture admission and failure accounting with
persistence. Logging can wait for finalization (up to three writes during recovery,
or four when stopping). Ordinary event-write contention still fails open and marks
a gap. A contended or failed stop remains retryable; lifecycle-lock retries last
at most one second.
Preparing a store already at the current schema version preserves its records, samples and non-reusable process registration sequences, including after cleanup.
Preparing an absent store creates it empty at that version.
Preparing a store at an upgradable version (`HistoryWorker::UPGRADABLE_VERSIONS`, currently 2) upgrades it in place and keeps its records: every change since that version only adds tables or indexes, so replaying the schema is the upgrade.
Keep schema changes additive so retained history survives them. A change that cannot be expressed that way must remove the affected versions from that list deliberately.
Preparing a store at any other version discards it, recreates it empty and sweeps the lock files of the discarded records, leaving in place any lock a running process still holds.
A collector running through that replacement registers a new lifecycle on its next write instead of retrying a completion for the discarded one, and the interval it left uncertified stays a gap.
Failures return fixed outcomes and collection records gaps without raising into
normal logging. Raw output through `<<` lacks severity metadata and invalidates
coverage. Output that bypasses the application logger is outside this guarantee.

Windows include their start and exclude their end. Use `window_end` for a completed
UTC interval. Repeat every selector with the returned `continuation` to traverse a
fixed snapshot; tokens expire after at most 15 minutes. Inspect coverage independently
of matching events and pagination. The argument contract retains the host's fixed
platform category selectors, whose application totals are empty. Platform retrieval
itself lives in the host and never enters retained totals.

Hosts derive the key themselves, for example from `Rails.application.key_generator`
with an application-specific salt. That derivation and all environment settings
remain outside the gem. The database schema, worker entrypoint and runtime requires
are packaged inside the gem; no host-relative paths or host constants are needed. The gem depends on ActiveSupport 8.1.3.1's once-only broadcast block
semantics, sqlite3, and the declared Ruby standard gems. Workers receive only the
load paths for the selected SQLite, JSON, time and date dependencies; they do not
boot the host bundle or inherit Ruby preloads. It is not a new logging framework
or backend interface.

## Installation

```ruby
gem "retained_logging", github: "ten-thousand-hammers/retained_logging", tag: "v0.1.1"
```

Implement the host settings described below. Inspection transports (such as an MCP
tool), platform log sources, Rails secrets, application scheduling, and
deployment-volume verification remain host responsibilities.

## Development

```sh
bundle install
bundle exec rake test               # unit tests, no Rails boot
bundle exec rake test:integration   # process lifecycle tests against a disposable Rails app
bundle exec rubocop
```

The unit tests build and extract the gem, then exercise its storage worker and
summaries from outside the repository.

## Rails integration

The gem loads its Railtie when required after Rails. Rails, Solid Queue and Puma
remain optional host dependencies; the adapters are verified with Rails 8.1.3.1,
Solid Queue 1.6.0 and Puma 8.0.2.

```ruby
# config/environments/production.rb
config.retained_logging.enabled = true
config.retained_logging.component = "web" # explicitly use "job" in the job component

# config/initializers/retained_logging.rb
Rails.application.config.retained_logging.history = -> {
  RetainedLogging::History.new(path: durable_path, scope: deployment_scope,
    key: Rails.application.key_generator.generate_key("your_app/retained_history/v1", 32))
}

# config/puma.rb
plugin :retained_logging
```

Use the application's existing configuration to supply the factory values. The
factory also serves `bin/rails retained_logging:prepare` and scheduled
`RetainedLogging.rails_integration.history.cleanup`. Preparation remains explicit;
keep the existing application's schedule for bounded 48-hour cleanup. Disabled
capture still permits preparation, cleanup and retained reads.

The Railtie installs the public broadcast logger before Rails shares it, attaches
capture after Rails configures key derivation, and registers process hooks once. Rails, Active Job,
and Solid Queue share one collector per OS process. Solid Queue start callbacks
restart checkpoint threads after forks. Its post-drain exit callbacks checkpoint
but keep capture attached for final instrumentation and other async roles; an
unfinished worker pool invalidates that interval. Ruby's `at_exit` closes normal
lifecycles; its handler is registered before application initializers so their exit
logging runs first. Hard exits leave an unverified tail.

Each collector holds a file lock beside the history database, in `<database>.owners/`.
All containers must share this directory and support POSIX file locks on the shared filesystem.
The existing cleanup job closes abandoned lifecycles only after it acquires their released locks.
Closure uses the observation time, so the interval after the last checkpoint remains a gap.
A live but stalled collector keeps its lock and remains incomplete.
Forked children close inherited descriptors without unlocking the parent's descriptor.
Storage workers do not inherit locks across `exec`.
Cleanup removes lock files when it removes their expired process records.

Legacy lifecycles have no lock files and require independent evidence that their owners stopped.
The operator task accepts one process UUID and a conservative UTC upper bound for its stop time:

```sh
RAILS_ENV=production bin/rails 'retained_logging:reconcile[PROCESS_UUID,2026-09-14T18:00:00Z]'
```

After you confirm the owner stopped, replace both example arguments with the corresponding evidence.
Do not use the last checkpoint as proof of process termination.
The task rejects future times, bounds before retained events or checkpoints, and owners with active locks.
It preserves existing completions and never creates captured intervals.
Only additive schema changes upgrade in place; a store at any other unexpected schema version is replaced rather than migrated.

`bin/rails 'retained_logging:verify[15]'` checks capture over a recent window (default 15 minutes, ending one minute ago).
It fails when a component certified nothing in the window, has not checkpointed in the last minute, or saw unsupported records.
A gap alone does not fail it, because a deployment inside the window leaves one.
Run it a few minutes after a deployment instead of waiting for a full day of history.

Puma requires the single plugin declaration because its launcher controls fork and
restart hooks outside Rails boot. The plugin ends preloaded collection before
forking, restarts child collection, and finalizes before hot restart's `exec`.
Normal exit waits until requests drain and final application exit handlers log.
The host needs no collector code in `bin/jobs` or its Solid Queue initializer.
Use separately attributed web and job processes; a shared-process queue cannot
assign different component labels to its shared logger.

The process integration tests (`test/integration`) run a disposable Rails app, real Solid Queue
workers in fork and async modes, and Puma in single and cluster modes, including
preloading and hot restart. They cover
shutdown draining, final logging, disabled capture and unfinished hard-exit tails.
These sandbox checks do not verify production volumes or a full day of collection.

## License

All rights reserved. The source is visible for reference only; use requires prior
written permission from Ten Thousand Hammers. See [LICENSE](LICENSE).
