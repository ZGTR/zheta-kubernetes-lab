import subprocess
import unittest
from pathlib import Path


class AmbientMeshSourceTest(unittest.TestCase):
    def test_ambient_source_contract(self):
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            ["bash", str(root / "scripts/verify-ambient-source.sh")],
            cwd=root,
            text=True,
            capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_cloud_overlays_remain_unenrolled(self):
        root = Path(__file__).resolve().parents[1]
        for environment in ("dev", "staging", "prod"):
            content = (root / "gitops/apps/forge/overlays" / environment / "kustomization.yaml").read_text()
            self.assertNotIn("mesh/ambient", content)

    def test_customer_ingress_is_an_explicit_veto(self):
        root = Path(__file__).resolve().parents[1]
        policy = (root / "gitops/apps/forge/mesh/ambient/l4-authorization.yaml").read_text()
        documentation = (root / "docs/istio-ambient.md").read_text()
        self.assertIn("sa/forge-waypoint", policy)
        self.assertIn("Customer ingress remains blocked", documentation)
        self.assertIn("169.254.7.127/32", (root / "gitops/apps/forge/mesh/ambient/health-probe-network-policy.yaml").read_text())
        self.assertIn("fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128", (root / "gitops/apps/forge/mesh/ambient/health-probe-network-policy.yaml").read_text())
        network_patch = (root / "gitops/apps/forge/mesh/ambient/network-policy-patch.yaml").read_text()
        self.assertEqual(3, network_patch.count("- ports: [{ protocol: TCP, port: 15008 }]"))

    def test_failure_and_rollback_require_exact_authority(self):
        root = Path(__file__).resolve().parents[1]
        failure = (root / "scripts/failure-istio-ambient.sh").read_text()
        rollback = (root / "scripts/rollback-istio-ambient.sh").read_text()
        self.assertIn("TARGET_POD_UID", failure)
        self.assertIn("positive_control", failure)
        self.assertIn("actual_owner", failure)
        self.assertIn("actual_label", failure)
        self.assertIn("len(items)==1", failure)
        self.assertIn("verify_mesh_product_policy", failure)
        self.assertNotIn("helm uninstall", rollback)
        self.assertNotIn("|| true", rollback)
        self.assertIn("supports only the local overlay", rollback)
        self.assertIn("rollout status deployment --all", rollback)


if __name__ == "__main__":
    unittest.main()
