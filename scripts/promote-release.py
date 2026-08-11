#!/usr/bin/env python3
"""Atomically replace a blocked cloud overlay with four real ECR digests."""
import re, sys
from pathlib import Path

environment, registry, *digests = sys.argv[1:]
if environment not in {"dev", "staging", "prod"} or len(digests) != 4:
    raise SystemExit("usage: promote-release.py dev|staging|prod ECR_REGISTRY CONTROL GENERATOR RUNTIME EVIDENCE")
if not re.fullmatch(r"[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com", registry):
    raise SystemExit("registry must be a real account-scoped ECR registry")
if any(not re.fullmatch(r"sha256:[0-9a-f]{64}", digest) for digest in digests):
    raise SystemExit("every service must have a real sha256 digest")
services = ("control-plane", "generator", "runtime", "evidence")
replicas = 3 if environment == "prod" else 2
images = "\n".join(f"  - name: zheta-forge/{service}\n    newName: {registry}/zheta-forge/{service}\n    digest: {digest}" for service, digest in zip(services, digests))
content = f'''apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [../../base, ready-policies.yaml, ready-capacity.yaml]
commonAnnotations: {{ zheta.io/release-state: digest-pinned }}
replicas:
{chr(10).join(f"  - {{ name: {service}, count: {replicas} }}" for service in services)}
configMapGenerator:
  - {{ name: forge-environment, namespace: zheta-forge, behavior: merge, literals: [ENVIRONMENT={environment}] }}
images:
{images}
'''
path = Path(__file__).resolve().parents[1] / "gitops" / "apps" / "forge" / "overlays" / environment / "kustomization.yaml"
path.write_text(content)
print(path)
