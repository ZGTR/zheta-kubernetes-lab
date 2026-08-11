from dataclasses import dataclass, field
from typing import Protocol

class Generator(Protocol):
    def generate(self, blueprint: dict[str, object]) -> dict[str, str]: ...
class Runtime(Protocol):
    def deploy(self, app_id: str, payload: dict[str, object]) -> dict[str, object]: ...
    def delete(self, app_id: str) -> None: ...
class Evidence(Protocol):
    def record(self, event: dict[str, object]) -> None: ...

@dataclass
class Project:
    project_id: str; organization_id: str; name: str; owner: str
    status: str = "draft"
    blueprint: dict[str, object] = field(default_factory=dict)
    artifacts: list[dict[str, str]] = field(default_factory=list)
    releases: list[dict[str, str]] = field(default_factory=list)
    collaborators: set[str] = field(default_factory=set)
    connector_grants: set[str] = field(default_factory=set)

class Forge:
    def __init__(self, generator: Generator, runtime: Runtime, evidence: Evidence) -> None:
        self.generator, self.runtime, self.evidence = generator, runtime, evidence
        self.projects: dict[str, Project] = {}
    def create(self, project_id: str, organization_id: str, name: str, actor: str) -> Project:
        if project_id in self.projects: raise ValueError("project already exists")
        p = Project(project_id, organization_id, name, actor, blueprint={"name": name}); p.collaborators.add(actor); self.projects[project_id] = p; self._audit(p, actor, "project.created"); return p
    def generate(self, p: Project, actor: str) -> dict[str, str]:
        self._authorize(p, actor); artifact = self.generator.generate(p.blueprint)
        if not any(a["artifact_id"] == artifact["artifact_id"] for a in p.artifacts): p.artifacts.append(artifact)
        self._audit(p, actor, "artifact.generated"); return artifact
    def preview(self, p: Project, actor: str) -> dict[str, object]:
        self._authorize(p, actor); result = self.runtime.deploy(p.project_id, {"mode": "preview", **self._latest(p)}); self._audit(p, actor, "preview.deployed"); return result
    def grant_connector(self, p: Project, actor: str, connector: str) -> None:
        self._owner(p, actor); p.connector_grants.add(connector); self._audit(p, actor, "connector.service_granted")
    def share(self, p: Project, actor: str, collaborator: str) -> None:
        self._owner(p, actor); p.collaborators.add(collaborator); self._audit(p, actor, "collaborator.shared")
    def revoke(self, p: Project, actor: str, collaborator: str) -> None:
        self._owner(p, actor)
        if collaborator == p.owner: raise ValueError("owner cannot be revoked")
        p.collaborators.discard(collaborator); self._audit(p, actor, "collaborator.revoked")
    def publish(self, p: Project, actor: str) -> dict[str, str]:
        self._owner(p, actor); artifact = self._latest(p); release = {"release_id": f"rel-{len(p.releases)+1}", "artifact_id": artifact["artifact_id"]}; p.releases.append(release); p.status = "published"; self.runtime.deploy(p.project_id, {"mode": "published", **release, **artifact}); self._audit(p, actor, "release.published"); return release
    def rollback(self, p: Project, actor: str, release_id: str) -> dict[str, str]:
        self._owner(p, actor); release = next((r for r in p.releases if r["release_id"] == release_id), None)
        if release is None: raise ValueError("release not found")
        artifact = next(a for a in p.artifacts if a["artifact_id"] == release["artifact_id"]); self.runtime.deploy(p.project_id, {"mode": "published", **release, **artifact}); self._audit(p, actor, "release.rolled_back"); return release
    def export(self, p: Project, actor: str) -> dict[str, object]: self._owner(p, actor); self._audit(p, actor, "project.exported"); return self.as_dict(p)
    def retire(self, p: Project, actor: str) -> None: self._owner(p, actor); p.status = "retired"; self.runtime.delete(p.project_id); self._audit(p, actor, "project.retired")
    def delete(self, p: Project, actor: str) -> None:
        self._owner(p, actor)
        if p.status != "retired": raise ValueError("retire project before deletion")
        self._audit(p, actor, "project.deleted"); del self.projects[p.project_id]
    @staticmethod
    def as_dict(p: Project) -> dict[str, object]: return {"project_id": p.project_id, "organization_id": p.organization_id, "name": p.name, "owner": p.owner, "status": p.status, "blueprint": p.blueprint, "artifacts": p.artifacts, "releases": p.releases, "collaborators": sorted(p.collaborators), "connector_grants": sorted(p.connector_grants)}
    def _audit(self, p: Project, actor: str, action: str) -> None: self.evidence.record({"project_id": p.project_id, "organization_id": p.organization_id, "actor": actor, "action": action})
    @staticmethod
    def _authorize(p: Project, actor: str) -> None:
        if actor not in p.collaborators: raise PermissionError("actor is not a collaborator")
    @staticmethod
    def _owner(p: Project, actor: str) -> None:
        if actor != p.owner: raise PermissionError("owner authority required")
    @staticmethod
    def _latest(p: Project) -> dict[str, str]:
        if not p.artifacts: raise ValueError("generate an artifact first")
        return p.artifacts[-1]
