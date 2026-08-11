import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.http import read_json, write_json
STATE: dict[str, dict[str, object]] = {}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz": write_json(self, 200, {"service": "runtime"}); return
        app_id = self.path.removeprefix("/apps/"); value = STATE.get(app_id)
        write_json(self, 200 if value else 404, value or {"error": "app not found"})
    def do_PUT(self) -> None:
        app_id = self.path.removeprefix("/apps/"); STATE[app_id] = {"app_id": app_id, **read_json(self)}; write_json(self, 200, STATE[app_id])
    def do_DELETE(self) -> None:
        app_id = self.path.removeprefix("/apps/"); existed = STATE.pop(app_id, None) is not None; write_json(self, 200 if existed else 404, {"deleted": existed})
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
