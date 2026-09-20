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

    def test_complete_consumer_and_retirement_evidence_passes(self) -> None:
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
        manifest["repositoryEvidence"]["milestones"]["consumerHistory"] = False
        manifest["repositoryEvidence"].pop("consumerHistoryEvidence")
        errors = self.errors(manifest)
        self.assertTrue(any("consumerHistory" in error for error in errors), errors)
        self.assertTrue(any("structured consumerHistoryEvidence" in error for error in errors), errors)

    def test_retirement_cannot_pass_while_adoption_is_pending(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["gates"]["consumer-adoption"]["result"] = "pending"
        manifest["gates"]["consumer-adoption"]["missingEvidence"] = ["consumer-history"]
        errors = self.errors(manifest)
        self.assertTrue(any("requires consumer-adoption" in error for error in errors), errors)

    def test_process_continuation_must_be_effect_isolated(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["repositoryEvidence"]["consumerHistoryEvidence"]["processContinuation"]["outboundEffectsEnabled"] = True
        errors = self.errors(manifest)
        self.assertTrue(any("disable outbound effects" in error for error in errors), errors)

    def test_empty_workflow_history_must_be_explicit(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["repositoryEvidence"]["consumerHistoryEvidence"]["workflowInventory"]["result"] = "passed"
        errors = self.errors(manifest)
        self.assertTrue(any("empty workflow history" in error for error in errors), errors)

    def test_retirement_must_use_the_replayed_candidate_patch(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["repositoryEvidence"]["retirementEvidence"]["candidatePatchSha256"] = "0" * 64
        errors = self.errors(manifest)
        self.assertTrue(any("adopted candidate patch" in error for error in errors), errors)

    def test_repository_manifest_never_claims_a_release_action(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["gates"]["package-release"]["action"] = "performed"
        self.assertTrue(any("must remain not-performed" in error for error in self.errors(manifest)))

    def test_removing_a_required_historical_reader_fails_the_gate(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["retainedImplementations"][0]["anchor"] = "removedCalendarDayReader"
        errors = self.errors(manifest)
        self.assertTrue(any("retained implementation anchor missing" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
