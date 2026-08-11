CREATE TABLE IF NOT EXISTS projects (organization_id TEXT NOT NULL, project_id TEXT NOT NULL, payload TEXT NOT NULL, version INTEGER NOT NULL, deleted_at TEXT, PRIMARY KEY (organization_id, project_id));
CREATE TABLE IF NOT EXISTS event_outbox (message_id TEXT PRIMARY KEY, payload TEXT NOT NULL, published_at TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT);
CREATE TABLE IF NOT EXISTS event_outbox_dead_letter (message_id TEXT PRIMARY KEY, payload TEXT NOT NULL, failed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, last_error TEXT NOT NULL);
