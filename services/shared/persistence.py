"""Injected durable SQL adapters; SQLite is the local analogue, PostgreSQL is cloud."""
import json
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any


class Database:
    def __init__(self, url: str) -> None:
        self.url = url
        self._lock = threading.RLock()
        self._local = threading.local()
        if url.startswith("sqlite:///"):
            self.kind = "sqlite"
            path = url.removeprefix("sqlite:///")
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            self.connection: Any = sqlite3.connect(path, check_same_thread=False)
        elif url.startswith("postgresql://"):
            self.kind = "postgresql"
            try:
                import psycopg
            except ImportError as error:
                raise RuntimeError("PostgreSQL configuration requires psycopg") from error
            self.connection = psycopg.connect(url, autocommit=True)
        else:
            raise ValueError("DATABASE_URL must be sqlite:///... or postgresql://...")

    def sql(self, statement: str) -> str:
        return statement if self.kind == "sqlite" else statement.replace("?", "%s")

    def execute(self, statement: str, values: tuple[object, ...] = ()):
        with self._lock:
            cursor = self.connection.execute(self.sql(statement), values)
            if self.kind == "sqlite" and not getattr(self._local, "transaction", False):
                self.connection.commit()
            return cursor

    @contextmanager
    def transaction(self):
        with self._lock:
            if getattr(self._local, "transaction", False):
                yield
                return
            self._local.transaction = True
            try:
                if self.kind == "sqlite": self.connection.execute("BEGIN IMMEDIATE")
                else: self.connection.execute("BEGIN")
                yield
                self.connection.commit()
            except Exception:
                self.connection.rollback()
                raise
            finally:
                self._local.transaction = False

    def one(self, statement: str, values: tuple[object, ...]) -> tuple[Any, ...] | None:
        with self._lock:
            cursor = self.connection.execute(self.sql(statement), values)
            return cursor.fetchone()

    def all(self, statement: str, values: tuple[object, ...] = ()) -> list[tuple[Any, ...]]:
        with self._lock:
            return list(self.connection.execute(self.sql(statement), values).fetchall())

    def migrate(self, name: str) -> None:
        path = Path(__file__).resolve().parents[1] / "migrations" / name
        with self.transaction():
            for statement in path.read_text().split(";"):
                if statement.strip(): self.execute(statement)


class JsonProjectRepository:
    def __init__(self, database: Database) -> None:
        self.database = database
        database.migrate("control.sql")

    def get(self, organization_id: str, project_id: str) -> dict[str, object] | None:
        row = self.database.one("SELECT payload, version FROM projects WHERE organization_id=? AND project_id=? AND deleted_at IS NULL", (organization_id, project_id))
        if not row: return None
        value = json.loads(row[0]); value["version"] = row[1]; return value

    def create(self, organization_id: str, project_id: str, payload: dict[str, object]) -> None:
        try:
            self.database.execute("INSERT INTO projects (organization_id, project_id, payload, version) VALUES (?, ?, ?, 1)", (organization_id, project_id, json.dumps(payload, sort_keys=True)))
        except sqlite3.IntegrityError as error:
            raise ValueError("project already exists") from error
        except Exception as error:
            if error.__class__.__name__ == "UniqueViolation":
                raise ValueError("project already exists") from error
            raise

    def save(self, organization_id: str, project_id: str, payload: dict[str, object], expected_version: int) -> int:
        cursor = self.database.execute("UPDATE projects SET payload=?, version=version+1 WHERE organization_id=? AND project_id=? AND version=? AND deleted_at IS NULL", (json.dumps(payload, sort_keys=True), organization_id, project_id, expected_version))
        if cursor.rowcount != 1: raise RuntimeError("concurrent project update; reload and retry")
        return expected_version + 1

    def tombstone(self, organization_id: str, project_id: str, expected_version: int) -> None:
        cursor = self.database.execute("UPDATE projects SET payload='{}', deleted_at=CURRENT_TIMESTAMP, version=version+1 WHERE organization_id=? AND project_id=? AND version=? AND deleted_at IS NULL", (organization_id, project_id, expected_version))
        if cursor.rowcount != 1: raise RuntimeError("concurrent project deletion; reload and retry")

    def transaction(self): return self.database.transaction()


class SqlEventStore:
    def __init__(self, database: Database) -> None:
        self.database = database
        database.migrate("evidence.sql")

    def append(self, event: dict[str, object]) -> bool:
        try:
            self.database.execute("INSERT INTO evidence_events (evidence_id, organization_id, project_id, payload) VALUES (?, ?, ?, ?)", (str(event["evidence_id"]), str(event["organization_id"]), str(event["project_id"]), json.dumps(event, sort_keys=True)))
            return True
        except sqlite3.IntegrityError:
            return False
        except Exception as error:
            if error.__class__.__name__ == "UniqueViolation": return False
            raise

    def events(self, organization_id: str) -> list[dict[str, object]]:
        return [json.loads(row[0]) for row in self.database.all("SELECT payload FROM evidence_events WHERE organization_id=? ORDER BY observed_at, evidence_id", (organization_id,))]
