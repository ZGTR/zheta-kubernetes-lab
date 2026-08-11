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
        policy = (root / "gitops/apps/forge/mesh/ambient-l7/l4-waypoint-patch.yaml").read_text()
        documentation = (root / "docs/istio-ambient.md").read_text()
        self.assertIn("sa/forge-waypoint", policy)
        self.assertIn("Customer ingress remains blocked", documentation)
        self.assertIn("169.254.7.127/32", (root / "gitops/apps/forge/mesh/ambient-enrollment/health-probe-network-policy.yaml").read_text())
        self.assertIn("fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128", (root / "gitops/apps/forge/mesh/ambient-enrollment/health-probe-network-policy.yaml").read_text())
        network_patch = (root / "gitops/apps/forge/mesh/ambient-enrollment/network-policy-patch.yaml").read_text()
        self.assertEqual(3, network_patch.count("- ports: [{ protocol: TCP, port: 15008 }]"))

    def test_progressive_overlays_do_not_teach_l7_early(self):
        root = Path(__file__).resolve().parents[1]
        enrollment = (root / "gitops/apps/forge/overlays/ambient-enrollment-local/kustomization.yaml").read_text()
        l4 = (root / "gitops/apps/forge/overlays/ambient-l4-local/kustomization.yaml").read_text()
        final = (root / "gitops/apps/forge/overlays/ambient-local/kustomization.yaml").read_text()
        self.assertIn("mesh/ambient-enrollment", enrollment)
        self.assertNotIn("ambient-l4", enrollment)
        self.assertNotIn("ambient-l7", enrollment)
        self.assertIn("mesh/ambient-l4", l4)
        self.assertNotIn("ambient-l7", l4)
        self.assertIn("mesh/ambient-l7", final)

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

    def test_waypoint_bypass_probe_is_bounded_live_evidence(self):
        root = Path(__file__).resolve().parents[1]
        probe = (root / "scripts/probe-istio-waypoint-bypass.sh").read_text()
        manifest = (root / "gitops/apps/forge/mesh/ambient-l4/bypass-observation-network-policy.yaml").read_text()
        documentation = (root / "docs/istio-ambient.md").read_text()
        self.assertIn("MESH_BYPASS_PROBE_APPROVED", probe)
        self.assertIn("SOURCE_POD_UID", probe)
        self.assertIn("TARGET_POD_UID", probe)
        self.assertIn("MESH_EVIDENCE_DIR", probe)
        self.assertIn("verify_mesh_l4_policy", probe)
        self.assertIn("verify_mesh_l7_policy", probe)
        self.assertIn("supports only the local overlay", probe)
        self.assertIn("ztunnel-observation.log", probe)
        self.assertIn("ztunnel_uid", probe)
        self.assertIn("target-IP:port/source-identity/policy-denial record", probe)
        self.assertIn('target=os.environ["TARGET_IP"]+":8080"', probe)
        self.assertIn("matches=[line for line", probe)
        self.assertIn("ztunnel-denial-record.log", probe)
        self.assertIn('timespec="microseconds"', probe)
        self.assertNotIn('grep -Fq "$target_ip"', probe)
        self.assertIn("allow-bounded-bypass-observation", manifest)
        self.assertIn("NETWORK_DENY_SOURCE_POD_UID", probe)
        self.assertIn("port: 8080", manifest)
        self.assertIn("port: 15008", manifest)
        self.assertIn("Live probe, not static proof", documentation)


if __name__ == "__main__":
    unittest.main()
