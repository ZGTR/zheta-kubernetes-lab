import hashlib
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.http import read_json, write_json

def generate(blueprint: dict[str, object]) -> dict[str, str]:
    digest = hashlib.sha256(repr(sorted(blueprint.items())).encode()).hexdigest()
    return {"artifact_id": f"sha256:{digest}", "source": f"<main><h1>{blueprint.get('name', 'Untitled app')}</h1></main>"}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        write_json(self, 200 if self.path == "/healthz" else 404, {"service": "generator"})
    def do_POST(self) -> None:
        write_json(self, 200, generate(read_json(self))) if self.path == "/generate" else write_json(self, 404, {"error": "not found"})
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
