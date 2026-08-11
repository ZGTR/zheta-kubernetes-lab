"""Fail-closed process configuration contracts."""
import os

def required_secret(name: str) -> str:
    value = os.getenv(name, "")
    if len(value) < 32: raise RuntimeError(f"{name} must have at least 32 characters")
    return value

def required_url(name: str, prefixes: tuple[str, ...]) -> str:
    value = os.getenv(name, "")
    if not value.startswith(prefixes): raise RuntimeError(f"{name} must use one of: {', '.join(prefixes)}")
    return value

def is_cloud() -> bool: return os.getenv("ENVIRONMENT", "local") in {"dev", "staging", "prod"}
