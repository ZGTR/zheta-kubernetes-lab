import runpy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).parents[1]
DIGESTS = [f"sha256:{character * 64}" for character in "abcde"]
REGISTRY = "123456789012.dkr.ecr.eu-west-2.amazonaws.com"
SERVICES = ("control-plane", "generator", "runtime", "evidence", "broker")


class ReleasePromotionTest(unittest.TestCase):
    def test_blocked_cloud_overlays_replace_every_mutable_base_tag(self):
        guard_digest = "digest: sha256:" + "0" * 64
        for environment in ("dev", "staging", "prod"):
            overlay = (ROOT / "gitops/apps/forge/overlays" / environment / "kustomization.yaml").read_text()
            self.assertIn("blocked-unpinned", overlay)
            self.assertEqual(5, overlay.count("promotion-blocked.invalid/zheta-forge/"))
            self.assertEqual(5, overlay.count(guard_digest))
            self.assertIn("name: zheta-forge/broker", overlay)

    def run_promote(self, digests):
        arguments = ["promote-release.py", "prod", REGISTRY, *digests]
        with patch.object(sys, "argv", arguments), patch("pathlib.Path.write_text") as write:
            runpy.run_path(str(ROOT / "scripts/promote-release.py"), run_name="__main__")
            return write.call_args.args[0]

    def test_promotion_requires_broker_digest(self):
        with self.assertRaisesRegex(SystemExit, "BROKER"):
            self.run_promote(DIGESTS[:-1])

    def test_promotion_pins_exactly_five_images(self):
        manifest = self.run_promote(DIGESTS)
        self.assertEqual(5, manifest.count("digest: sha256:"))
        for service, digest in zip(SERVICES, DIGESTS):
            self.assertIn(f"name: zheta-forge/{service}\n", manifest)
            self.assertIn(f"newName: {REGISTRY}/zheta-forge/{service}\n    digest: {digest}", manifest)


class ReleaseLaunchTest(unittest.TestCase):
    def candidate(self, services):
        images = "\n".join(
            f"  - name: zheta-forge/{service}\n    newName: {REGISTRY}/zheta-forge/{service}\n    digest: {digest}"
            for service, digest in zip(services, DIGESTS)
        )
        return (
            "commonAnnotations: { zheta.io/release-state: digest-pinned-awaiting-private-launch }\n"
            "configMapGenerator:\n"
            f"images:\n{images}\n"
        )

    def run_launch(self, manifest):
        arguments = ["launch-release.py", "prod"]
        with (
            patch.object(sys, "argv", arguments),
            patch("pathlib.Path.read_text", return_value=manifest),
            patch("pathlib.Path.write_text") as write,
        ):
            runpy.run_path(str(ROOT / "scripts/launch-release.py"), run_name="__main__")
            return write.call_args.args[0]

    def test_launch_rejects_legacy_four_digest_candidate(self):
        with self.assertRaisesRegex(SystemExit, "including broker"):
            self.run_launch(self.candidate(SERVICES[:-1]))

    def test_launch_rejects_malformed_broker_digest(self):
        with self.assertRaisesRegex(SystemExit, "including broker"):
            self.run_launch(self.candidate(SERVICES).replace(DIGESTS[-1], "sha256:not-immutable"))

    def test_launch_preserves_broker_pin_while_using_managed_cloud_broker(self):
        launched = self.run_launch(self.candidate(SERVICES))
        self.assertIn("name: zheta-forge/broker", launched)
        self.assertIn("private-contracts-proven", launched)
        self.assertNotIn("{ name: broker, count:", launched)


if __name__ == "__main__":
    unittest.main()
