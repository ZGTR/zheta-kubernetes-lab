import hashlib
import html
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.http import read_json, write_json

def generate(blueprint: dict[str, object]) -> dict[str, str]:
    digest = hashlib.sha256(repr(sorted(blueprint.items())).encode()).hexdigest()
    name = html.escape(str(blueprint.get("name", "Untitled app")))
    archetype = str(blueprint.get("archetype", "workflow"))
    templates = {
        "workflow": f"<main><h1>{name}</h1><form><button>Submit request</button></form></main>",
        "dashboard": f"<main><h1>{name}</h1><section aria-label='metrics'>No metrics yet</section></main>",
        "knowledge-base": f"<main><h1>{name}</h1><input aria-label='Search knowledge' /></main>",
    }
    if archetype not in templates:
        raise ValueError("unsupported archetype")
    return {"artifact_id": f"sha256:{digest}", "source": templates[archetype]}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        write_json(self, 200 if self.path == "/healthz" else 404, {"service": "generator"})
    def do_POST(self) -> None:
        try:
            require_service_token(self.headers.get("X-Service-Token"), SERVICE_TOKEN)
            write_json(self, 200, generate(read_json(self))) if self.path == "/generate" else write_json(self, 404, {"error": "not found"})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def log_message(self, format: str, *args: object) -> None: return

from services.shared.auth import require_service_token
SERVICE_TOKEN = os.getenv("SERVICE_TOKEN", "")
if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
