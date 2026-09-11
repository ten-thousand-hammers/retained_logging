# Retained logging

An in-repository Bundler path gem for safe application evidence. It retains bounded
metadata and keyed pattern identifiers in SQLite for 48 hours, with checkpoints
that distinguish captured silence from missing collection. It retains no raw text,
credentials, parameters, or stack traces.

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
logger assignment, activation, process lifecycle hooks and scheduled `history.cleanup`.
History creation is explicit; ordinary writes and reads never prepare the schema.
Writes have a one-second worker budget; reads have an eight-second budget.
Failures return fixed outcomes and collection records gaps without raising into
normal logging. Raw output through `<<` lacks severity metadata and invalidates
coverage. Output that bypasses the application logger is outside this guarantee.

Windows include their start and exclude their end. Use `window_end` for a completed
UTC interval. Repeat every selector with the returned `continuation` to traverse a
fixed snapshot; tokens expire after at most 15 minutes. Inspect coverage independently
of matching events and pagination. The argument contract retains the host's fixed
platform category selectors, whose application totals are empty. Platform retrieval
itself lives in the host and never enters retained totals.

Grabarr derives the key from `Rails.application.key_generator` using
`production_inspection/retained_history/v1`. That derivation and all environment
settings remain outside the gem. The database schema, worker entrypoint and runtime
requires are packaged inside the gem; no host-relative paths or Grabarr constants
are needed. The gem depends on ActiveSupport 8.1.3.1's once-only broadcast block
semantics, sqlite3, and the declared Ruby standard gems. Workers receive only the
load paths for the selected SQLite, JSON, time and date dependencies; they do not
boot the host bundle or inherit Ruby preloads. It is not a new logging framework
or backend interface.

Run from the host bundle without Rails boot:

```sh
bin/bundle exec ruby gems/retained_logging/test/retained_logging_test.rb
```

The tests build and extract the gem, then exercise its storage worker and summaries
from outside the repository. To extract later, copy this directory, provide a bundle
with its gemspec dependencies and test dependencies (`minitest`), and implement the
host wiring described above. MCP, Dokploy, Rails secrets, application scheduling,
and deployment-volume verification remain host responsibilities. No publication
workflow or production rollout is implied by the package tests.
