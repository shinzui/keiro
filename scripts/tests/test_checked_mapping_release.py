from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-checked-mapping-release.py"
MANIFEST = ROOT / "keiro-dsl" / "test" / "fixtures" / "checked-mapping-replay-workspace" / "release-manifest.json"

SPEC = importlib.util.spec_from_file_location("check_checked_mapping_release", SCRIPT)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def load_manifest() -> dict:
    with MANIFEST.open(encoding="utf-8") as handle:
        return json.load(handle)


class CheckedMappingReleaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = load_manifest()

    def errors(self, manifest=None) -> list[str]:
        return CHECKER.validate(self.manifest if manifest is None else manifest, ROOT)

    def test_truthful_pending_consumer_and_retirement_gates_pass(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_cli_reports_all_four_independent_gates(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), str(MANIFEST), "--root", str(ROOT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        for gate in CHECKER.GATES:
            self.assertIn(f"{gate}=", completed.stdout)

    def test_missing_policy_golden_blocks_package_eligibility(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["wirePolicies"][0]["goldens"] = []
        errors = self.errors(manifest)
        self.assertTrue(any("no goldens" in error for error in errors), errors)

    def test_consumer_adoption_cannot_pass_without_real_history(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["gates"]["consumer-adoption"]["result"] = "eligible"
        errors = self.errors(manifest)
        self.assertTrue(any("consumerHistory" in error for error in errors), errors)
        self.assertTrue(any("missingEvidence" in error for error in errors), errors)

    def test_retirement_cannot_pass_while_adoption_is_pending(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["gates"]["implementation-retirement"]["result"] = "eligible"
        errors = self.errors(manifest)
        self.assertTrue(any("requires consumer-adoption" in error for error in errors), errors)
        self.assertTrue(any("requires a retirement rehearsal" in error for error in errors), errors)

    def test_repository_manifest_never_claims_a_release_action(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["gates"]["package-release"]["action"] = "performed"
        self.assertTrue(any("must remain not-performed" in error for error in self.errors(manifest)))


if __name__ == "__main__":
    unittest.main()
