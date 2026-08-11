import hashlib, json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.http import read_json, write_json
EVENTS: list[dict[str, object]] = []

class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz": write_json(self, 200, {"service": "evidence"})
        elif self.path == "/events": write_json(self, 200, {"events": EVENTS})
        else: write_json(self, 404, {"error": "not found"})
    def do_POST(self) -> None:
        if self.path != "/events": write_json(self, 404, {"error": "not found"}); return
        event = read_json(self); event["observed_at"] = int(time.time()); event["evidence_id"] = hashlib.sha256(json.dumps(event, sort_keys=True).encode()).hexdigest(); EVENTS.append(event); write_json(self, 201, event)
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
