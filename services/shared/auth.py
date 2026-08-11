"""HMAC JWT verification used at the public provider boundary."""
import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class Identity:
    actor: str
    organization_id: str


def _decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def verify_bearer(header: str | None, secret: str, issuer: str, audience: str) -> Identity:
    if not header or not header.startswith("Bearer ") or len(secret) < 32:
        raise PermissionError("valid bearer authentication required")
    token = header.removeprefix("Bearer ")
    try:
        encoded_header, encoded_claims, encoded_signature = token.split(".")
        signed = f"{encoded_header}.{encoded_claims}".encode()
        expected = hmac.new(secret.encode(), signed, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _decode(encoded_signature)):
            raise PermissionError("invalid bearer signature")
        claims = json.loads(_decode(encoded_claims))
    except (ValueError, json.JSONDecodeError):
        raise PermissionError("malformed bearer token") from None
    if claims.get("iss") != issuer or claims.get("aud") != audience or int(claims.get("exp", 0)) <= int(time.time()):
        raise PermissionError("expired or wrong-scope bearer token")
    if not claims.get("sub") or not claims.get("org"):
        raise PermissionError("bearer token lacks tenant identity")
    return Identity(str(claims["sub"]), str(claims["org"]))


def require_service_token(value: str | None, expected: str) -> None:
    if len(expected) < 32 or not value or not hmac.compare_digest(value, expected):
        raise PermissionError("service authentication required")
