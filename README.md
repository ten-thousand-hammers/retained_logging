# Retained logging

A gem for bounded application evidence. It keeps 48 hours of warning, error and
failed-request history for a Rails application, together with checkpoints that
tell captured silence apart from missing collection.

Each captured message becomes a keyed fingerprint of its normalized text. Each
fingerprint also keeps one readable sample of the original message, clipped to
512 bytes on a whole-character boundary. The sample comes from the first message
that produced the fingerprint and is never overwritten. Cleanup deletes it once no
retained occurrence carries that fingerprint, so it does not outlive the 48 hour
window. Anyone who can read the store or the host's read surface can read that
text, so the host controls access to both. Nothing else is retained: URLs,
parameters, credentials and stack traces have no columns of their own and reach
storage only inside a captured message.

## Installation

```ruby
gem "retained_logging", github: "ten-thousand-hammers/retained_logging", tag: "v0.2.1"
```

The store is any database Active Record supports. The suite runs against SQLite
and Postgres. Bundle the adapter you use.

## Storage

History lives in its own database, declared in `config/database.yml` like any other
named database. Its migrations ship in the gem, so `bin/rails db:prepare` creates
and migrates it:

```yaml
production:
  primary:
    # ...
  retained_logging:
    <<: *default
    database: myapp_production_retained_logging
    migrations_paths: <%= RetainedLogging::MIGRATIONS_PATH %>
```

```ruby
# config/application.rb or an environment file
config.retained_logging.database = :retained_logging
```

Rails reads `RETAINED_LOGGING_DATABASE_URL` for a database named `retained_logging`,
as it does for any named database. Rails also dumps the store's schema to
`db/retained_logging_schema.rb`; commit it like the other schema files.

Store records use their own connection pool. History writes are therefore
independent of the application's connections and transactions: a rolled-back
request still leaves its errors in history.

Capture writes on the logging thread, one short transaction per warning or error.
Configure the store so that a slow or unavailable database fails fast instead of
holding up logging. Failures become fixed outcomes and recorded gaps, and they
never raise into normal logging. Suggested settings:

```yaml
# Postgres
retained_logging:
  connect_timeout: 2
  checkout_timeout: 1
  variables:
    statement_timeout: 8000 # reads summarize up to 48 hours
    lock_timeout: 1000

# SQLite
retained_logging:
  timeout: 1000 # milliseconds to wait for another writer
```

Writes to one lifecycle are serialized through `SELECT ... FOR UPDATE`. Postgres
locks the row. SQLite's immediate transactions lock the whole store, which is
correct but serializes every writer, so prefer Postgres when several machines
share history. Postgres is also the only choice when processes do not share a
filesystem. Store failures map to fixed outcomes: `timeout` for a cancelled
statement, `contention` for busy stores, lock waits, deadlocks and pool timeouts,
and `unavailable` for everything else, including a store whose migrations have
not run.

## Rails integration

The gem loads its Railtie when required after Rails. Rails, Solid Queue and Puma
remain optional host dependencies. The adapters are verified with Rails 8.1,
Solid Queue 1.6 and Puma 8.0.

```ruby
# config/environments/production.rb
config.retained_logging.enabled = true
config.retained_logging.component = "web" # explicitly use "job" in the job component
config.retained_logging.database = :retained_logging

# config/initializers/retained_logging.rb
Rails.application.config.retained_logging.history = -> {
  RetainedLogging::History.new(scope: deployment_scope,
    key: Rails.application.key_generator.generate_key("your_app/retained_history/v1", 32))
}

# config/puma.rb
plugin :retained_logging
```

```yaml
# config/recurring.yml (Solid Queue), or any scheduler
retained_logging_cleanup:
  command: "RetainedLogging.rails_integration.history.cleanup"
  schedule: every minute
```

The host supplies `web`/`job` attribution, a stable scope and a key of at least
32 bytes, and scheduled cleanup. Derive the key in the host, for example from
`Rails.application.key_generator` with an application-specific salt. Disabled
capture still permits cleanup and retained reads.

The Railtie installs the public broadcast logger before Rails shares it, attaches
capture after Rails configures key derivation, and registers process hooks once.
Rails, Active Job and Solid Queue share one collector per OS process. Solid Queue
start callbacks restart checkpoint threads after forks. Its post-drain exit
callbacks checkpoint but keep capture attached for final instrumentation and other
async roles; an unfinished worker pool invalidates that interval. Ruby's `at_exit`
closes normal lifecycles. Its handler is registered before application
initializers, so their exit logging runs first. Hard exits leave an unverified tail.

Puma requires the single plugin declaration because its launcher controls fork and
restart hooks outside Rails boot. The plugin ends preloaded collection before
forking, restarts child collection, and finalizes before hot restart's `exec`.
Normal exit waits until requests drain and final application exit handlers log.
The host needs no collector code in `bin/jobs` or its Solid Queue initializer.
Use separately attributed web and job processes; a shared-process queue cannot
assign different component labels to its shared logger.

Use INFO or lower to capture failed requests logged at INFO. Checkpoints reject
coverage when registered sources filter INFO, so do not silence health checks or
Solid Queue polling while capture is enabled: silencing lowers the log level.

### Abandoned lifecycles

Collectors write at least every ten seconds while they run. Cleanup closes a
lifecycle that has written nothing for five minutes
(`RetainedLogging::Store::ABANDONED_SECONDS`), whether its process exited without
finishing or stalled. Closure uses the observation time, so the interval after the
last checkpoint is reported as a gap and never as coverage. A stalled collector
that later writes again is refused, closes its old lifecycle and registers a new
one.

### Verifying capture

`bin/rails 'retained_logging:verify[15]'` checks capture over a recent window
(default 15 minutes, ending one minute ago). It fails when a component certified
nothing in the window, has not checkpointed in the last minute, or saw unsupported
records. A gap alone does not fail it, because a deployment inside the window
leaves one. Run it a few minutes after a deployment instead of waiting for a full
day of history.

## Reading history

```ruby
result = RetainedLogging::RetainedLogs.new(history: history).call(
  "component" => "all", "lookback_minutes" => 1440, "limit" => 100)
```

Windows include their start and exclude their end. Use `window_end` for a completed
UTC interval. Repeat every selector with the returned `continuation` to traverse a
fixed snapshot; tokens expire after at most 15 minutes. Inspect coverage
independently of matching events and pagination. The argument contract keeps the
host's fixed platform category selectors, whose application totals are empty.
Platform retrieval itself lives in the host and never enters retained totals.
Inspection transports (such as an MCP tool), platform log sources and secrets
remain host responsibilities.

## Without Rails

```ruby
require "retained_logging"
require "active_support/tagged_logging"

RetainedLogging::Record.establish_connection(adapter: "sqlite3", database: "history.sqlite3")
# Run RetainedLogging::MIGRATIONS_PATH with your migration tooling first.
history = RetainedLogging::History.new(scope: deployment_scope, key: derived_key)
collector = RetainedLogging::Capture.new(history: history, component: "web")
logger = RetainedLogging::Capture.install(stdout_logger, collector)
collector.start
logger.tagged("request-id") { |log| log.warn("application warning") }
collector.stop # graceful completion; arrange host process and fork hooks
```

Keep the returned logger in every caller. Installation preserves the original
output loggers and adds one metadata destination through ActiveSupport's public
broadcast API. Reinstalling the returned logger is idempotent. Tags and lazy
blocks work in both tagged forms, and original output destinations keep their
formatters and devices. A host can install a `RetainedLogging::BroadcastLogger`
before sharing its logger, then attach capture with `Capture.install` once storage
configuration is ready.

Checkpoint finalization serializes capture admission and failure accounting with
persistence. Logging can wait for finalization (up to three writes during
recovery, or four when stopping). Ordinary event-write contention still fails open
and marks a gap. Raw output through `<<` lacks severity metadata and invalidates
coverage. Output that bypasses the application logger is outside this guarantee.
Anything the store itself logs while it writes is not captured.

## Upgrading from 0.1

Version 0.2 stores history through Active Record, in new `retained_logging_*`
tables, instead of a SQLite file written by child processes.

- Declare the store in `database.yml` and set `config.retained_logging.database`
  (see Storage), then run `bin/rails db:prepare`.
- `History.new` takes `scope:` and `key:`; `path:` is gone.
- `retained_logging:prepare` is replaced by `bin/rails db:prepare`.
- `retained_logging:reconcile` is gone: cleanup now closes abandoned lifecycles.
- The previous SQLite file and its `.owners/` and `.prepare` companions are no
  longer read. Delete them after the upgrade. History restarts empty, so the first
  48 hours after the upgrade show `warm_up`.

## Development

```sh
bundle install
bundle exec rake test               # unit tests, no Rails boot
bundle exec rake test:integration   # process lifecycle tests against a disposable Rails app
bundle exec rubocop
```

Both suites use SQLite by default. Set `RETAINED_LOGGING_TEST_POSTGRES_URL` to a
disposable Postgres database to run them against Postgres; CI runs both.

The unit tests also build and extract the gem, then migrate a store and serve
history from outside the repository. The integration tests run a disposable Rails
app, real Solid Queue workers in fork and async modes, and Puma in single and
cluster modes, including preloading and hot restart. They cover shutdown
draining, final logging, disabled capture, unprepared stores and unfinished
hard-exit tails. These sandbox checks do not verify a production deployment or a
full day of collection.

## License

All rights reserved. The source is visible for reference only; use requires prior
written permission from Ten Thousand Hammers. Bundled Brand has that permission for
its own products and services. See [LICENSE](LICENSE).
