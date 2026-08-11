import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from services.shared.auth import require_service_token
from services.shared.http import read_json, write_json
from services.shared.persistence import Database

SERVICE_TOKEN = os.getenv("SERVICE_TOKEN", "")
DATABASE = Database(os.getenv("RUNTIME_DATABASE_URL", "sqlite:///.lab/runtime.db"))
DATABASE.migrate("runtime.sql")

class Handler(BaseHTTPRequestHandler):
    def authenticate(self): require_service_token(self.headers.get("X-Service-Token"), SERVICE_TOKEN)
    def key(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 4 or parts[0] != "tenants" or parts[2] != "apps": raise ValueError("invalid tenant app path")
        return parts[1], parts[3]
    def do_GET(self):
        if self.path == "/healthz": write_json(self, 200, {"service": "runtime"}); return
        try:
            self.authenticate(); organization_id, app_id = self.key(); row = DATABASE.one("SELECT payload FROM runtime_apps WHERE organization_id=? AND app_id=? AND deleted_at IS NULL", (organization_id, app_id)); write_json(self, 200 if row else 404, json.loads(row[0]) if row else {"error": "app not found"})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def do_PUT(self):
        try:
            self.authenticate(); organization_id, app_id = self.key(); payload = {"organization_id": organization_id, "app_id": app_id, **read_json(self)}; existing = DATABASE.one("SELECT app_id FROM runtime_apps WHERE organization_id=? AND app_id=?", (organization_id, app_id))
            if existing: DATABASE.execute("UPDATE runtime_apps SET payload=?, deleted_at=NULL WHERE organization_id=? AND app_id=?", (json.dumps(payload, sort_keys=True), organization_id, app_id))
            else: DATABASE.execute("INSERT INTO runtime_apps (organization_id, app_id, payload) VALUES (?, ?, ?)", (organization_id, app_id, json.dumps(payload, sort_keys=True)))
            write_json(self, 200, payload)
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def do_DELETE(self):
        try:
            self.authenticate(); organization_id, app_id = self.key(); DATABASE.execute("UPDATE runtime_apps SET payload='{}', deleted_at=CURRENT_TIMESTAMP WHERE organization_id=? AND app_id=?", (organization_id, app_id)); write_json(self, 200, {"tombstoned": True})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__": ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
