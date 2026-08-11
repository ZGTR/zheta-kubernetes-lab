import os, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.auth import require_service_token
from services.shared.broker import subscriber_from_url
from services.shared.http import write_json
from services.shared.persistence import Database, SqlEventStore
from services.shared.config import is_cloud, required_secret, required_url

SERVICE_TOKEN = os.getenv("SERVICE_TOKEN", "")
required_secret("SERVICE_TOKEN")
if is_cloud():
    required_url("EVIDENCE_DATABASE_URL", ("postgresql://",))
    required_url("BROKER_SUBSCRIPTION", ("https://sqs.", "https://sqs-"))
STORE = SqlEventStore(Database(os.getenv("EVIDENCE_DATABASE_URL", "sqlite:///.lab/evidence.db")))
BROKER = subscriber_from_url(os.getenv("BROKER_SUBSCRIPTION", "http://broker:8080"), SERVICE_TOKEN)

def subscribe() -> None:
    while True:
        try:
            for receipt, event in BROKER.receive("evidence"):
                event["evidence_id"] = event.get("evidence_id") or __import__("hashlib").sha256(__import__("json").dumps(event, sort_keys=True).encode()).hexdigest()
                STORE.append(event)
                BROKER.acknowledge("evidence", receipt)
        except Exception: time.sleep(2)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz": write_json(self, 200, {"service": "evidence"}); return
        try:
            require_service_token(self.headers.get("X-Service-Token"), SERVICE_TOKEN); organization_id = urllib.parse.unquote(self.path.removeprefix("/events?organization_id=")); write_json(self, 200, {"events": STORE.events(organization_id)})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__":
    threading.Thread(target=subscribe, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
