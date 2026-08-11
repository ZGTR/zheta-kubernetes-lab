#!/usr/bin/env python3
import base64, hashlib, hmac, json, os, time
secret = os.getenv("JWT_SECRET", "local-jwt-secret-32-characters-minimum")
encode = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
header = encode({"alg": "HS256", "typ": "JWT"})
claims = encode({"sub": os.getenv("ACTOR", "owner@acme.test"), "org": os.getenv("ORGANIZATION_ID", "acme"), "iss": "helixworks-forge", "aud": "forge-control-plane", "exp": int(time.time()) + 300})
signed = f"{header}.{claims}"
signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), signed.encode(), hashlib.sha256).digest()).decode().rstrip("=")
print(f"{signed}.{signature}")
