"""View/transport layer plus composition root for injected adapters."""
import json, os, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from services.control_plane.adapters import S3ArtifactStore, SqlArtifactStore, SqlProjectRepository
from services.control_plane.controller import ForgeController
from services.control_plane.domain import Forge
from services.shared.auth import verify_bearer
from services.shared.http import read_json, write_json
from services.shared.persistence import Database, JsonProjectRepository
from services.shared.broker import publisher_from_url
from services.control_plane.outbox import OutboxPublisher
from services.shared.config import is_cloud, required_secret, required_url

SERVICE_TOKEN = os.environ.get("SERVICE_TOKEN", "")
JWT_SECRET = os.environ.get("JWT_SECRET", "")
JWT_ISSUER = os.environ.get("JWT_ISSUER", "zheta-forge")
JWT_AUDIENCE = os.environ.get("JWT_AUDIENCE", "forge-control-plane")
required_secret("SERVICE_TOKEN")
required_secret("JWT_SECRET")
if is_cloud():
    required_url("CONTROL_DATABASE_URL", ("postgresql://",))
    required_url("BROKER_TOPIC", ("arn:aws:sns:",))
    required_url("GENERATOR_URL", ("http://", "https://"))
    required_url("RUNTIME_URL", ("http://", "https://"))
    required_url("EVIDENCE_URL", ("http://", "https://"))
    if not os.getenv("ARTIFACT_BUCKET"): raise RuntimeError("ARTIFACT_BUCKET is required in cloud environments")

def request_json(method: str, url: str, body: dict[str, object] | None = None) -> dict[str, Any]:
    request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method, headers={"Content-Type": "application/json", "X-Service-Token": SERVICE_TOKEN})
    with urllib.request.urlopen(request, timeout=5) as response: return json.load(response)
class GeneratorClient:
    def __init__(self, url: str) -> None: self.url = url
    def generate(self, blueprint): return request_json("POST", f"{self.url}/generate", blueprint)
class RuntimeClient:
    def __init__(self, url: str) -> None: self.url = url
    def deploy(self, organization_id, app_id, payload): return request_json("PUT", f"{self.url}/tenants/{organization_id}/apps/{app_id}", payload)
    def delete(self, organization_id, app_id): request_json("DELETE", f"{self.url}/tenants/{organization_id}/apps/{app_id}")
def build_controller() -> ForgeController:
    database = Database(os.getenv("CONTROL_DATABASE_URL", "sqlite:///.lab/control.db"))
    repository = SqlProjectRepository(JsonProjectRepository(database))
    artifact_store = S3ArtifactStore(os.environ["ARTIFACT_BUCKET"]) if os.getenv("ARTIFACT_BUCKET") else SqlArtifactStore(Database(os.getenv("ARTIFACT_DATABASE_URL", "sqlite:///.lab/artifacts.db")))
    outbox = OutboxPublisher(database, publisher_from_url(os.getenv("BROKER_TOPIC", "http://broker:8080"), SERVICE_TOKEN)); outbox.start()
    forge = Forge(repository, GeneratorClient(os.getenv("GENERATOR_URL", "http://generator:8080")), RuntimeClient(os.getenv("RUNTIME_URL", "http://runtime:8080")), artifact_store, outbox)
    return ForgeController(forge)

CONTROLLER = build_controller()

class Handler(BaseHTTPRequestHandler):
    def identity(self): return verify_bearer(self.headers.get("Authorization"), JWT_SECRET, JWT_ISSUER, JWT_AUDIENCE)
    def do_GET(self):
        if self.path == "/healthz": write_json(self, 200, {"service": "control-plane"}); return
        if self.path == "/evidence":
            try:
                identity = self.identity(); result = request_json("GET", f"{os.getenv('EVIDENCE_URL', 'http://evidence:8080')}/events?organization_id={urllib.parse.quote(identity.organization_id)}"); write_json(self, 200, result)
            except PermissionError as error: write_json(self, 401, {"error": str(error)})
            return
        try: write_json(self, 200, CONTROLLER.get(self.identity(), self.path.removeprefix("/projects/").split("/", 1)[0]))
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
        except KeyError as error: write_json(self, 404, {"error": str(error)})
    def do_POST(self):
        try: result, status = CONTROLLER.command(self.identity(), self.path, read_json(self), self.headers.get("Idempotency-Key", "")); write_json(self, status, result)
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
        except KeyError as error: write_json(self, 404, {"error": str(error)})
        except ValueError as error: write_json(self, 409, {"error": str(error)})
    def do_DELETE(self):
        try: CONTROLLER.delete(self.identity(), self.path.removeprefix("/projects/")); write_json(self, 200, {"deleted": True})
        except PermissionError as error: write_json(self, 401, {"error": str(error)})
        except KeyError as error: write_json(self, 404, {"error": str(error)})
        except ValueError as error: write_json(self, 409, {"error": str(error)})
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__": ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
