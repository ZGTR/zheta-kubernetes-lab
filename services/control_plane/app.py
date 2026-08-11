import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from services.control_plane.domain import Forge
from services.shared.http import read_json, write_json

def request_json(method: str, url: str, body: dict[str, object] | None = None) -> dict[str, Any]:
    request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response: return json.load(response)
class GeneratorClient:
    def __init__(self, url: str) -> None: self.url = url
    def generate(self, blueprint: dict[str, object]) -> dict[str, str]: return request_json("POST", f"{self.url}/generate", blueprint)
class RuntimeClient:
    def __init__(self, url: str) -> None: self.url = url
    def deploy(self, app_id: str, payload: dict[str, object]) -> dict[str, object]: return request_json("PUT", f"{self.url}/apps/{app_id}", payload)
    def delete(self, app_id: str) -> None: request_json("DELETE", f"{self.url}/apps/{app_id}")
class EvidenceClient:
    def __init__(self, url: str) -> None: self.url = url
    def record(self, event: dict[str, object]) -> None: request_json("POST", f"{self.url}/events", event)

FORGE = Forge(GeneratorClient(os.getenv("GENERATOR_URL", "http://generator:8080")), RuntimeClient(os.getenv("RUNTIME_URL", "http://runtime:8080")), EvidenceClient(os.getenv("EVIDENCE_URL", "http://evidence:8080")))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz": write_json(self, 200, {"service": "control-plane"}); return
        p = FORGE.projects.get(self.path.removeprefix("/projects/").split("/", 1)[0]); write_json(self, 200 if p else 404, FORGE.as_dict(p) if p else {"error": "project not found"})
    def do_POST(self) -> None:
        try:
            result, status = self._route(read_json(self), self.headers.get("X-Actor", "")); write_json(self, status, result)
        except PermissionError as error: write_json(self, 403, {"error": str(error)})
        except (KeyError, ValueError) as error: write_json(self, 409, {"error": str(error)})
    def do_DELETE(self) -> None:
        project_id = self.path.removeprefix("/projects/"); p = FORGE.projects.get(project_id)
        if not p: write_json(self, 404, {"error": "project not found"}); return
        try: FORGE.delete(p, self.headers.get("X-Actor", "")); write_json(self, 200, {"deleted": True})
        except PermissionError as error: write_json(self, 403, {"error": str(error)})
        except ValueError as error: write_json(self, 409, {"error": str(error)})
    def _route(self, body: dict[str, Any], actor: str) -> tuple[dict[str, object], int]:
        if self.path == "/projects": return FORGE.as_dict(FORGE.create(body["project_id"], body["organization_id"], body["name"], actor)), 201
        project_id, action = self.path.removeprefix("/projects/").split("/", 1); p = FORGE.projects[project_id]
        if action == "generate": return FORGE.generate(p, actor), 201
        if action == "preview": return FORGE.preview(p, actor), 200
        if action == "connectors": FORGE.grant_connector(p, actor, body["connector"])
        elif action == "share": FORGE.share(p, actor, body["collaborator"])
        elif action == "revoke": FORGE.revoke(p, actor, body["collaborator"])
        elif action == "publish": return FORGE.publish(p, actor), 201
        elif action == "rollback": return FORGE.rollback(p, actor, body["release_id"]), 200
        elif action == "export": return FORGE.export(p, actor), 200
        elif action == "retire": FORGE.retire(p, actor)
        else: raise ValueError("unknown action")
        return FORGE.as_dict(p), 200
    def log_message(self, format: str, *args: object) -> None: return

if __name__ == "__main__": ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler).serve_forever()
