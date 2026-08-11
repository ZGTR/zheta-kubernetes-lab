#!/usr/bin/env python3
"""Validate account-bound images and decoded cloud secret contracts from stdin."""
import base64
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

SERVICES = ("control-plane", "generator", "runtime", "evidence")

def fail(message: str) -> None:
    raise SystemExit(f"launch veto: {message}")

def decoded_secrets(document: dict[str, object]) -> dict[str, dict[str, str]]:
    items = document.get("items", [])
    if not isinstance(items, list): fail("kubectl secret response is not a List")
    result: dict[str, dict[str, str]] = {}
    for item in items:
        if not isinstance(item, dict): fail("invalid secret item")
        metadata, data = item.get("metadata", {}), item.get("data", {})
        if not isinstance(metadata, dict) or not isinstance(data, dict): fail("invalid secret structure")
        name = metadata.get("name")
        if not isinstance(name, str): fail("secret lacks metadata.name")
        try: result[name] = {str(key): base64.b64decode(str(value), validate=True).decode() for key, value in data.items()}
        except Exception as error: fail(f"{name} contains invalid base64 or UTF-8: {error}")
    return result

def require(values: dict[str, str], secret: str, key: str) -> str:
    value = values.get(key, "")
    if not value: fail(f"{secret} lacks {key}")
    return value

def postgres(value: str, name: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "postgresql" or not parsed.hostname or not parsed.path.strip("/"):
        fail(f"{name} must be a PostgreSQL URL with host and database")

def service_url(value: str, name: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        fail(f"{name} must be an HTTP(S) URL with a host")

def validate(manifest: Path, account: str, region: str, document: dict[str, object]) -> None:
    if not re.fullmatch(r"[0-9]{12}", account): fail("expected account must contain 12 digits")
    if not re.fullmatch(r"[a-z]{2}(?:-gov)?-[a-z]+-[0-9]", region): fail("invalid AWS region")
    text = manifest.read_text()
    image_pattern = re.compile(r"newName: ([0-9]{12})\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/zheta-forge/([a-z-]+)$", re.MULTILINE)
    images = image_pattern.findall(text)
    if {service for _, _, service in images} != set(SERVICES) or len(images) != len(SERVICES):
        fail("overlay must bind exactly the four Forge ECR repositories")
    if any(image_account != account or image_region != region for image_account, image_region, _ in images):
        fail("every ECR image must match EXPECTED_AWS_ACCOUNT_ID and AWS_REGION")

    secrets = decoded_secrets(document)
    expected = {f"{service}-secrets" for service in SERVICES}
    if set(secrets) != expected: fail("exactly four workload secrets are required")
    tokens = []
    for secret in sorted(expected):
        token = require(secrets[secret], secret, "SERVICE_TOKEN")
        if len(token) < 32: fail(f"{secret} SERVICE_TOKEN must have at least 32 characters")
        tokens.append(token)
    if len(set(tokens)) != 1: fail("SERVICE_TOKEN must match across all four services")

    control = secrets["control-plane-secrets"]
    jwt = require(control, "control-plane-secrets", "JWT_SECRET")
    if len(jwt) < 32: fail("JWT_SECRET must have at least 32 characters")
    postgres(require(control, "control-plane-secrets", "CONTROL_DATABASE_URL"), "CONTROL_DATABASE_URL")
    service_url(require(control, "control-plane-secrets", "EVIDENCE_URL"), "EVIDENCE_URL")
    bucket = require(control, "control-plane-secrets", "ARTIFACT_BUCKET")
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket): fail("ARTIFACT_BUCKET is not a valid bucket name")
    topic = require(control, "control-plane-secrets", "BROKER_TOPIC")
    if not re.fullmatch(rf"arn:aws:sns:{re.escape(region)}:{account}:[A-Za-z0-9_.-]+\.fifo", topic):
        fail("BROKER_TOPIC must be a FIFO SNS ARN in the expected account and region")

    postgres(require(secrets["runtime-secrets"], "runtime-secrets", "RUNTIME_DATABASE_URL"), "RUNTIME_DATABASE_URL")
    evidence = secrets["evidence-secrets"]
    postgres(require(evidence, "evidence-secrets", "EVIDENCE_DATABASE_URL"), "EVIDENCE_DATABASE_URL")
    subscription = require(evidence, "evidence-secrets", "BROKER_SUBSCRIPTION")
    if not re.fullmatch(rf"https://sqs\.{re.escape(region)}\.amazonaws\.com/{account}/[A-Za-z0-9_.-]+\.fifo", subscription):
        fail("BROKER_SUBSCRIPTION must be a FIFO SQS URL in the expected account and region")

def main() -> None:
    if len(sys.argv) != 4: fail("usage: validate-launch-contract.py MANIFEST ACCOUNT REGION")
    validate(Path(sys.argv[1]), sys.argv[2], sys.argv[3], json.load(sys.stdin))

if __name__ == "__main__": main()
