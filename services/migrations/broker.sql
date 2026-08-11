CREATE TABLE IF NOT EXISTS topic_messages (message_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS topic_deliveries (message_id TEXT NOT NULL, subscriber TEXT NOT NULL, acknowledged_at TEXT, PRIMARY KEY (message_id, subscriber));
