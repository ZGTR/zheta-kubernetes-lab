import unittest
from services.control_plane.domain import Forge
from services.generator.app import generate

class FakeGenerator:
    def generate(self, blueprint): return generate(blueprint)
class FakeRuntime:
    def __init__(self): self.apps = {}
    def deploy(self, app_id, payload): self.apps[app_id] = payload; return payload
    def delete(self, app_id): self.apps.pop(app_id, None)
class FakeEvidence:
    def __init__(self): self.events = []
    def record(self, event): self.events.append(event)

class ForgeLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.runtime, self.evidence = FakeRuntime(), FakeEvidence(); self.forge = Forge(FakeGenerator(), self.runtime, self.evidence); self.project = self.forge.create("helpdesk", "acme", "Support triage", "owner")
    def test_complete_lifecycle_is_deterministic_and_audited(self):
        first = self.forge.generate(self.project, "owner"); second = self.forge.generate(self.project, "owner"); self.assertEqual(first["artifact_id"], second["artifact_id"]); self.assertEqual(1, len(self.project.artifacts)); self.forge.preview(self.project, "owner"); self.forge.grant_connector(self.project, "owner", "crm-reader"); self.forge.share(self.project, "owner", "reviewer"); release = self.forge.publish(self.project, "owner"); self.forge.rollback(self.project, "owner", release["release_id"]); exported = self.forge.export(self.project, "owner"); self.forge.retire(self.project, "owner"); self.forge.delete(self.project, "owner"); self.assertEqual("helpdesk", exported["project_id"]); self.assertGreaterEqual(len(self.evidence.events), 10)
    def test_planes_do_not_inherit_authority(self):
        self.forge.share(self.project, "owner", "reviewer"); self.forge.generate(self.project, "reviewer")
        with self.assertRaises(PermissionError): self.forge.publish(self.project, "reviewer")
        with self.assertRaises(ValueError): self.forge.delete(self.project, "owner")

if __name__ == "__main__": unittest.main()
