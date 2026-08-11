import base64, hashlib, hmac, json, tempfile, time, unittest
from pathlib import Path
from services.control_plane.adapters import SqlArtifactStore, SqlProjectRepository
from services.control_plane.domain import Forge
from services.generator.app import generate
from services.shared.auth import verify_bearer
from services.shared.persistence import Database, JsonProjectRepository, SqlEventStore
from services.shared.broker import SQLiteTopic, parse_sqs_body

class FakeGenerator:
    def generate(self, blueprint): return generate(blueprint)
class FakeRuntime:
    def __init__(self): self.apps = {}
    def deploy(self, organization_id, app_id, payload): self.apps[(organization_id, app_id)] = payload; return payload
    def delete(self, organization_id, app_id): self.apps.pop((organization_id, app_id), None)
class DurableEvents:
    def __init__(self, store): self.store = store
    def publish(self, event):
        canonical = json.dumps(event, sort_keys=True); event = {**event, "evidence_id": hashlib.sha256(canonical.encode()).hexdigest()}; self.store.append(event)

class ForgeLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); root = Path(self.temp.name)
        control = Database(f"sqlite:///{root / 'control.db'}"); artifacts = Database(f"sqlite:///{root / 'artifacts.db'}"); evidence = Database(f"sqlite:///{root / 'evidence.db'}")
        self.repository = SqlProjectRepository(JsonProjectRepository(control)); self.artifacts = SqlArtifactStore(artifacts); self.events = SqlEventStore(evidence); self.runtime = FakeRuntime()
        self.forge = Forge(self.repository, FakeGenerator(), self.runtime, self.artifacts, DurableEvents(self.events))
        self.project = self.forge.create("helpdesk", "acme", "Support triage", "owner", "workflow")
    def tearDown(self): self.temp.cleanup()
    def test_restart_multi_instance_and_idempotent_publish(self):
        self.forge.generate(self.project, "owner")
        second_instance = Forge(self.repository, FakeGenerator(), self.runtime, self.artifacts, DurableEvents(self.events))
        restored = second_instance.get("acme", "helpdesk")
        first = second_instance.publish(restored, "owner", "request-1"); duplicate = self.forge.publish(self.forge.get("acme", "helpdesk"), "owner", "request-1")
        self.assertEqual(first, duplicate); self.assertEqual(1, len(self.forge.get("acme", "helpdesk").releases))
    def test_tenant_boundary_and_tombstone_preserve_evidence(self):
        with self.assertRaises(KeyError): self.forge.get("other-org", "helpdesk")
        self.forge.generate(self.project, "owner"); self.forge.retire(self.project, "owner"); self.forge.delete(self.project, "owner")
        self.assertIsNone(self.repository.get("acme", "helpdesk")); self.assertTrue(any(e["action"] == "project.deleted" for e in self.events.events("acme")))
    def test_generated_archetypes_escape_xss(self):
        for archetype in ("workflow", "dashboard", "knowledge-base"):
            source = generate({"name": "<script>alert(1)</script>", "archetype": archetype})["source"]
            self.assertNotIn("<script>", source); self.assertIn("&lt;script&gt;", source)

class AuthenticationTest(unittest.TestCase):
    def token(self, claims, secret):
        encode = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
        header, payload = encode({"alg": "HS256", "typ": "JWT"}), encode(claims); signed = f"{header}.{payload}"; signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), signed.encode(), hashlib.sha256).digest()).decode().rstrip("="); return f"{signed}.{signature}"
    def test_signed_tenant_claims_are_authoritative(self):
        secret = "s" * 32; token = self.token({"sub": "owner", "org": "acme", "iss": "issuer", "aud": "audience", "exp": int(time.time()) + 60}, secret)
        identity = verify_bearer(f"Bearer {token}", secret, "issuer", "audience"); self.assertEqual("acme", identity.organization_id)
        with self.assertRaises(PermissionError): verify_bearer(f"Bearer {token[:-1]}x", secret, "issuer", "audience")
        with self.assertRaises(PermissionError): verify_bearer(None, secret, "issuer", "audience")

class PubSubTest(unittest.TestCase):
    def test_local_fanout_has_independent_subscriber_acknowledgements(self):
        with tempfile.TemporaryDirectory() as root:
            topic = SQLiteTopic(f"sqlite:///{root}/topic.db"); topic.publish("m1", {"action": "published"})
            topic.acknowledge("evidence", "m1")
            self.assertEqual([], topic.receive("evidence")); self.assertEqual("m1", topic.receive("operations")[0][0])
    def test_sqs_parser_accepts_raw_and_sns_envelope(self):
        event = {"action": "published"}
        self.assertEqual(event, parse_sqs_body(json.dumps(event)))
        self.assertEqual(event, parse_sqs_body(json.dumps({"Message": json.dumps(event)})))

if __name__ == "__main__": unittest.main()
