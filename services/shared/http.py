import json
from http.server import BaseHTTPRequestHandler
from typing import Any

def read_json(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0"))
    return json.loads(handler.rfile.read(length)) if length else {}

def write_json(handler: BaseHTTPRequestHandler, status: int, value: Any) -> None:
    body = json.dumps(value, sort_keys=True).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
