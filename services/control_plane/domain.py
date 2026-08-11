"""Model layer: tenant-scoped product rules with injected ports."""
from dataclasses import asdict, dataclass, field
from typing import Protocol


class ProjectRepository(Protocol):
    def get(self, organization_id: str, project_id: str) -> "Project | None": ...
    def create(self, project: "Project") -> None: ...
    def save(self, project: "Project") -> None: ...
    def tombstone(self, project: "Project") -> None: ...
    def transaction(self): ...


class Generator(Protocol):
    def generate(self, blueprint: dict[str, object]) -> dict[str, str]: ...


class Runtime(Protocol):
    def deploy(self, organization_id: str, app_id: str, payload: dict[str, object]) -> dict[str, object]: ...
    def delete(self, organization_id: str, app_id: str) -> None: ...


class ArtifactStore(Protocol):
    def put(self, organization_id: str, artifact_id: str, source: str) -> None: ...
    def get(self, organization_id: str, artifact_id: str) -> str: ...


class EventPublisher(Protocol):
    def publish(self, event: dict[str, object]) -> None: ...


@dataclass
class Project:
    project_id: str
    organization_id: str
    name: str
    owner: str
    status: str = "draft"
    blueprint: dict[str, object] = field(default_factory=dict)
    artifacts: list[dict[str, str]] = field(default_factory=list)
    releases: list[dict[str, str]] = field(default_factory=list)
    collaborators: set[str] = field(default_factory=set)
    connector_grants: set[str] = field(default_factory=set)
    version: int = 1


class Forge:
    def __init__(self, repository: ProjectRepository, generator: Generator, runtime: Runtime, artifacts: ArtifactStore, events: EventPublisher) -> None:
        self.repository, self.generator, self.runtime, self.artifacts, self.events = repository, generator, runtime, artifacts, events

    def get(self, organization_id: str, project_id: str) -> Project:
        project = self.repository.get(organization_id, project_id)
        if project is None:
            raise KeyError("project not found")
        return project

    def create(self, project_id: str, organization_id: str, name: str, actor: str, archetype: str) -> Project:
        project = Project(project_id, organization_id, name, actor, blueprint={"name": name, "archetype": archetype})
        project.collaborators.add(actor)
        with self.repository.transaction():
            self.repository.create(project)
            self._audit(project, actor, "project.created")
        return project

    def generate(self, project: Project, actor: str) -> dict[str, str]:
        self._authorize(project, actor)
        generated = self.generator.generate(project.blueprint)
        self.artifacts.put(project.organization_id, generated["artifact_id"], generated["source"])
        artifact = {"artifact_id": generated["artifact_id"]}
        if artifact not in project.artifacts:
            project.artifacts.append(artifact)
        with self.repository.transaction():
            self.repository.save(project)
            self._audit(project, actor, "artifact.generated")
        return artifact

    def preview(self, project: Project, actor: str) -> dict[str, object]:
        self._authorize(project, actor)
        artifact = self._latest(project)
        payload = {"mode": "preview", **artifact, "source": self.artifacts.get(project.organization_id, artifact["artifact_id"])}
        result = self.runtime.deploy(project.organization_id, project.project_id, payload)
        self._audit(project, actor, "preview.deployed")
        return result

    def grant_connector(self, project: Project, actor: str, connector: str) -> None:
        self._owner(project, actor)
        project.connector_grants.add(connector)
        self._save_and_audit(project, actor, "connector.service_granted")

    def share(self, project: Project, actor: str, collaborator: str) -> None:
        self._owner(project, actor)
        project.collaborators.add(collaborator)
        self._save_and_audit(project, actor, "collaborator.shared")

    def revoke(self, project: Project, actor: str, collaborator: str) -> None:
        self._owner(project, actor)
        if collaborator == project.owner:
            raise ValueError("owner cannot be revoked")
        project.collaborators.discard(collaborator)
        self._save_and_audit(project, actor, "collaborator.revoked")

    def publish(self, project: Project, actor: str, idempotency_key: str) -> dict[str, str]:
        self._owner(project, actor)
        if not idempotency_key:
            raise ValueError("Idempotency-Key required")
        existing = next((release for release in project.releases if release["idempotency_key"] == idempotency_key), None)
        if existing:
            if existing.get("state") == "deployed": return existing
            return self._complete_publish(project, actor, existing)
        artifact = self._latest(project)
        release = {"release_id": f"rel-{len(project.releases) + 1}", "artifact_id": artifact["artifact_id"], "idempotency_key": idempotency_key, "state": "pending"}
        project.releases.append(release)
        project.status = "published"
        with self.repository.transaction():
            self.repository.save(project)
            self._audit(project, actor, "release.requested")
        return self._complete_publish(project, actor, release)

    def _complete_publish(self, project: Project, actor: str, release: dict[str, str]) -> dict[str, str]:
        self.runtime.deploy(project.organization_id, project.project_id, {"mode": "published", **release, "source": self.artifacts.get(project.organization_id, release["artifact_id"])})
        release["state"] = "deployed"
        with self.repository.transaction():
            self.repository.save(project)
            self._audit(project, actor, "release.published")
        return release

    def rollback(self, project: Project, actor: str, release_id: str) -> dict[str, str]:
        self._owner(project, actor)
        release = next((item for item in project.releases if item["release_id"] == release_id), None)
        if release is None:
            raise ValueError("release not found")
        self.runtime.deploy(project.organization_id, project.project_id, {"mode": "published", **release, "source": self.artifacts.get(project.organization_id, release["artifact_id"])})
        self._audit(project, actor, "release.rolled_back")
        return release

    def export(self, project: Project, actor: str) -> dict[str, object]:
        self._owner(project, actor)
        self._audit(project, actor, "project.exported")
        return self.as_dict(project)

    def retire(self, project: Project, actor: str) -> None:
        self._owner(project, actor)
        project.status = "retired"
        with self.repository.transaction():
            self.repository.save(project)
            self._audit(project, actor, "project.retired")
        self.runtime.delete(project.organization_id, project.project_id)

    def delete(self, project: Project, actor: str) -> None:
        self._owner(project, actor)
        if project.status != "retired":
            raise ValueError("retire project before deletion")
        with self.repository.transaction():
            self._audit(project, actor, "project.deleted")
            self.repository.tombstone(project)

    @staticmethod
    def as_dict(project: Project) -> dict[str, object]:
        value = asdict(project)
        value["collaborators"] = sorted(project.collaborators)
        value["connector_grants"] = sorted(project.connector_grants)
        return value

    def _save_and_audit(self, project: Project, actor: str, action: str) -> None:
        with self.repository.transaction():
            self.repository.save(project)
            self._audit(project, actor, action)

    def _audit(self, project: Project, actor: str, action: str) -> None:
        self.events.publish({"project_id": project.project_id, "organization_id": project.organization_id, "actor": actor, "action": action})

    @staticmethod
    def _authorize(project: Project, actor: str) -> None:
        if actor not in project.collaborators:
            raise PermissionError("actor is not a collaborator")

    @staticmethod
    def _owner(project: Project, actor: str) -> None:
        if actor != project.owner:
            raise PermissionError("owner authority required")

    @staticmethod
    def _latest(project: Project) -> dict[str, str]:
        if not project.artifacts:
            raise ValueError("generate an artifact first")
        return project.artifacts[-1]
