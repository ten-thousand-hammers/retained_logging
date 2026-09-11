CREATE TABLE processes_v2 (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  scope TEXT NOT NULL,
  component TEXT NOT NULL CHECK (component IN ('web', 'job')),
  started_at INTEGER NOT NULL,
  ended_at INTEGER CHECK (ended_at >= started_at)
);
INSERT INTO processes_v2(sequence, id, scope, component, started_at, ended_at)
  SELECT rowid, id, scope, component, started_at, ended_at FROM processes ORDER BY rowid;
DROP TABLE processes;
ALTER TABLE processes_v2 RENAME TO processes;
