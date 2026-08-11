CREATE TABLE IF NOT EXISTS runtime_apps (organization_id TEXT NOT NULL, app_id TEXT NOT NULL, payload TEXT NOT NULL, deleted_at TEXT, PRIMARY KEY (organization_id, app_id));
