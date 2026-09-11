CREATE TABLE IF NOT EXISTS processes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  scope TEXT NOT NULL,
  component TEXT NOT NULL CHECK (component IN ('web', 'job')),
  started_at INTEGER NOT NULL,
  ended_at INTEGER CHECK (ended_at >= started_at)
);
CREATE INDEX IF NOT EXISTS processes_scope ON processes(scope, component);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  process_id TEXT NOT NULL REFERENCES processes(id),
  occurred_at INTEGER NOT NULL,
  recorded_at INTEGER NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('errors', 'warnings', 'failed_requests')),
  status INTEGER CHECK (status BETWEEN 400 AND 599),
  pattern TEXT NOT NULL CHECK (length(pattern) <= 80)
);
CREATE INDEX IF NOT EXISTS events_window ON events(occurred_at, id);
CREATE INDEX IF NOT EXISTS events_process ON events(process_id);
CREATE TABLE IF NOT EXISTS checkpoints (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  process_id TEXT NOT NULL REFERENCES processes(id),
  starts_at INTEGER NOT NULL,
  ends_at INTEGER NOT NULL CHECK (ends_at >= starts_at),
  recorded_at INTEGER NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('captured', 'gap')),
  informational_count INTEGER NOT NULL CHECK (informational_count >= 0),
  unsupported_count INTEGER NOT NULL CHECK (unsupported_count >= 0)
);
CREATE INDEX IF NOT EXISTS checkpoints_window ON checkpoints(ends_at, id);
CREATE INDEX IF NOT EXISTS checkpoints_process ON checkpoints(process_id, ends_at);
CREATE TABLE IF NOT EXISTS completions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  process_id TEXT NOT NULL UNIQUE REFERENCES processes(id) ON DELETE CASCADE,
  ended_at INTEGER NOT NULL
);
PRAGMA user_version = 1;
