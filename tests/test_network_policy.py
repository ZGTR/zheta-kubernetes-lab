import subprocess
import unittest
from pathlib import Path


class KindNetworkPolicyContractTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]

    def test_kindnet_and_node_are_immutably_pinned(self):
        versions = (self.root / "platform/kind/versions.env").read_text()
        terraform = (self.root / "terraform/main.tf").read_text()
        variables = (self.root / "terraform/variables.tf").read_text()
        self.assertIn("KIND_VERSION=v0.32.0", versions)
        self.assertIn("KINDNET_IMAGE=docker.io/kindest/kindnetd:", versions)
        self.assertRegex(versions, r"KIND_NODE_IMAGE=kindest/node:v[0-9.]+@sha256:[0-9a-f]{64}")
        self.assertIn("node_image      = var.kind_node_image", terraform)
        self.assertIn("sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95", variables)

    def test_live_probe_fails_closed_and_binds_exact_workloads(self):
        probe = (self.root / "scripts/probe-network-policy.sh").read_text()
        for contract in (
            "ALLOWED_SOURCE_POD_UID",
            "DENIED_SOURCE_POD_UID",
            "DENIED_SOURCE_CONTROL_POD_UID",
            "TARGET_POD_UID",
            "NETWORK_POLICY_EVIDENCE_DIR",
            "namespace is already Ambient-enrolled",
            'negative_status" = 42',
            "positive_controls",
            "verify-kind-network-policy.sh",
        ):
            self.assertIn(contract, probe)
        self.assertIn("cni-probe:", (self.root / "Makefile").read_text())

    def test_new_shell_contracts_parse(self):
        for script in ("verify-kind-network-policy.sh", "probe-network-policy.sh", "probe-istio-l4-authorization.sh"):
            result = subprocess.run(["bash", "-n", str(self.root / "scripts" / script)], capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
