import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.auth import require_service_token
from services.shared.broker import SQLiteTopic
from services.shared.http import read_json, write_json

TOKEN = os.getenv("SERVICE_TOKEN", "")
TOPIC = SQLiteTopic(os.getenv("BROKER_DATABASE_URL", "sqlite:///.lab/broker.db"))
class Handler(BaseHTTPRequestHandler):
    def auth(self): require_service_token(self.headers.get("X-Service-Token"), TOKEN)
    def do_GET(self):
        if self.path == "/healthz": write_json(self, 200, {"service": "broker"}); return
        try: self.auth(); subscriber = self.path.removeprefix("/subscriptions/"); write_json(self, 200, {"messages": TOPIC.receive(subscriber)})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def do_POST(self):
        try:
            self.auth(); body = read_json(self)
            if self.path == "/messages": TOPIC.publish(body["message_id"], body["payload"])
            elif self.path.startswith("/subscriptions/"): TOPIC.acknowledge(self.path.removeprefix("/subscriptions/"), body["receipt"])
            else: write_json(self, 404, {"error": "not found"}); return
            write_json(self, 200, {"accepted": True})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def log_message(self, format: str, *args: object) -> None: return
if __name__ == "__main__": ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
