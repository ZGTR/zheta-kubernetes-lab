"""Controller layer: maps authenticated product commands onto the model."""
from typing import Any
from services.control_plane.domain import Forge
from services.shared.auth import Identity


class ForgeController:
    def __init__(self, forge: Forge) -> None:
        self.forge = forge

    def get(self, identity: Identity, project_id: str) -> dict[str, object]:
        project = self.forge.get(identity.organization_id, project_id)
        self.forge._authorize(project, identity.actor)
        return self.forge.as_dict(project)

    def command(self, identity: Identity, path: str, body: dict[str, Any], idempotency_key: str = "") -> tuple[dict[str, object], int]:
        if path == "/projects":
            if body["organization_id"] != identity.organization_id:
                raise PermissionError("token tenant does not match requested tenant")
            project = self.forge.create(body["project_id"], identity.organization_id, body["name"], identity.actor, body["archetype"])
            return self.forge.as_dict(project), 201
        project_id, action = path.removeprefix("/projects/").split("/", 1)
        project = self.forge.get(identity.organization_id, project_id)
        if action == "generate": return self.forge.generate(project, identity.actor), 201
        if action == "preview": return self.forge.preview(project, identity.actor), 200
        if action == "connectors": self.forge.grant_connector(project, identity.actor, body["connector"])
        elif action == "share": self.forge.share(project, identity.actor, body["collaborator"])
        elif action == "revoke": self.forge.revoke(project, identity.actor, body["collaborator"])
        elif action == "publish": return self.forge.publish(project, identity.actor, idempotency_key), 201
        elif action == "rollback": return self.forge.rollback(project, identity.actor, body["release_id"]), 200
        elif action == "export": return self.forge.export(project, identity.actor), 200
        elif action == "retire": self.forge.retire(project, identity.actor)
        else: raise ValueError("unknown action")
        return self.forge.as_dict(project), 200

    def delete(self, identity: Identity, project_id: str) -> None:
        self.forge.delete(self.forge.get(identity.organization_id, project_id), identity.actor)
