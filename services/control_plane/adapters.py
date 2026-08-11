"""Infrastructure adapters implementing model ports."""
import json
from services.control_plane.domain import Project
from services.shared.persistence import JsonProjectRepository


class SqlProjectRepository:
    def __init__(self, repository: JsonProjectRepository) -> None:
        self.repository = repository

    def get(self, organization_id: str, project_id: str) -> Project | None:
        value = self.repository.get(organization_id, project_id)
        if value is None:
            return None
        value["collaborators"] = set(value["collaborators"])
        value["connector_grants"] = set(value["connector_grants"])
        return Project(**value)

    def create(self, project: Project) -> None:
        self.repository.create(project.organization_id, project.project_id, _payload(project))

    def save(self, project: Project) -> None:
        project.version = self.repository.save(project.organization_id, project.project_id, _payload(project), project.version)

    def tombstone(self, project: Project) -> None:
        self.repository.tombstone(project.organization_id, project.project_id, project.version)

    def transaction(self): return self.repository.transaction()


def _payload(project: Project) -> dict[str, object]:
    value = project.__dict__.copy()
    value["collaborators"] = sorted(project.collaborators)
    value["connector_grants"] = sorted(project.connector_grants)
    return json.loads(json.dumps(value))


class SqlArtifactStore:
    def __init__(self, database) -> None:
        self.database = database
        database.migrate("artifacts.sql")

    def put(self, organization_id: str, artifact_id: str, source: str) -> None:
        if not self.database.one("SELECT artifact_id FROM artifacts WHERE organization_id=? AND artifact_id=?", (organization_id, artifact_id)):
            self.database.execute("INSERT INTO artifacts (organization_id, artifact_id, source) VALUES (?, ?, ?)", (organization_id, artifact_id, source))

    def get(self, organization_id: str, artifact_id: str) -> str:
        row = self.database.one("SELECT source FROM artifacts WHERE organization_id=? AND artifact_id=?", (organization_id, artifact_id))
        if not row:
            raise ValueError("artifact not found")
        return str(row[0])


class S3ArtifactStore:
    def __init__(self, bucket: str) -> None:
        import boto3
        self.bucket = bucket
        self.client = boto3.client("s3")

    def put(self, organization_id: str, artifact_id: str, source: str) -> None:
        self.client.put_object(Bucket=self.bucket, Key=f"control-plane/{organization_id}/{artifact_id}", Body=source.encode(), ServerSideEncryption="aws:kms")

    def get(self, organization_id: str, artifact_id: str) -> str:
        return self.client.get_object(Bucket=self.bucket, Key=f"control-plane/{organization_id}/{artifact_id}")["Body"].read().decode()
