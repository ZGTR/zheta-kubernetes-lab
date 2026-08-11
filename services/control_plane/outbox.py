"""Transactional-outbox seam with retryable broker relay."""
import hashlib, json, threading, time

class OutboxPublisher:
    def __init__(self, database, broker) -> None:
        self.database, self.broker = database, broker
        database.migrate("control.sql")
    def publish(self, event: dict[str, object]) -> None:
        canonical = json.dumps(event, sort_keys=True); message_id = hashlib.sha256(canonical.encode()).hexdigest()
        if not self.database.one("SELECT message_id FROM event_outbox WHERE message_id=?", (message_id,)):
            self.database.execute("INSERT INTO event_outbox (message_id, payload) VALUES (?, ?)", (message_id, canonical))
    def relay(self) -> None:
        for message_id, payload in self.database.all("SELECT message_id, payload FROM event_outbox WHERE published_at IS NULL ORDER BY message_id LIMIT 100"):
            try:
                self.broker.publish(message_id, json.loads(payload)); self.database.execute("UPDATE event_outbox SET published_at=CURRENT_TIMESTAMP, last_error=NULL WHERE message_id=?", (message_id,))
            except Exception as error:
                self.database.execute("UPDATE event_outbox SET attempts=attempts+1, last_error=? WHERE message_id=?", (str(error), message_id))
                row = self.database.one("SELECT attempts FROM event_outbox WHERE message_id=?", (message_id,))
                if row and row[0] >= 10:
                    self.database.execute("INSERT INTO event_outbox_dead_letter (message_id, payload, last_error) VALUES (?, ?, ?)", (message_id, payload, str(error)))
                    self.database.execute("UPDATE event_outbox SET published_at=CURRENT_TIMESTAMP WHERE message_id=?", (message_id,))
    def run(self) -> None:
        while True:
            self.relay()
            time.sleep(2)
    def start(self) -> None: threading.Thread(target=self.run, daemon=True).start()
