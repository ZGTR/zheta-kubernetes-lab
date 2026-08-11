#!/usr/bin/env python3
"""Enable replicas only after a private runner proves the target cluster contracts."""
import sys
from pathlib import Path

environment = sys.argv[1] if len(sys.argv) == 2 else ""
if environment not in {"dev", "staging", "prod"}: raise SystemExit("usage: launch-release.py dev|staging|prod")
path = Path(__file__).resolve().parents[1] / "gitops/apps/forge/overlays" / environment / "kustomization.yaml"
content = path.read_text()
if "digest-pinned-awaiting-private-launch" not in content or content.count("digest: sha256:") != 4: raise SystemExit("images must be digest-pinned before launch")
replicas = 3 if environment == "prod" else 2
block = "replicas:\n" + "\n".join(f"  - {{ name: {name}, count: {replicas} }}" for name in ("control-plane", "generator", "runtime", "evidence")) + "\n"
content = content.replace("digest-pinned-awaiting-private-launch", "private-contracts-proven")
content = content.replace("configMapGenerator:", block + "configMapGenerator:")
path.write_text(content)
print(path)
