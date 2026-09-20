from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-replay-compatibility.py"
FIXTURES = Path(__file__).with_name("fixtures") / "replay-compatibility"

SPEC = importlib.util.spec_from_file_location("check_replay_compatibility", SCRIPT)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def load(name: str) -> dict:
    with (FIXTURES / name).open(encoding="utf-8") as handle:
        return json.load(handle)


class ReplayCompatibilityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.inventory = load("inventory-v1.json")
        self.baseline = load("baseline-v1.json")
        self.candidate = load("candidate-v1.json")

    def errors(self, *, inventory=None, baseline=None, candidate=None) -> list[str]:
        return CHECKER.check(
            self.baseline if baseline is None else baseline,
            self.candidate if candidate is None else candidate,
            self.inventory if inventory is None else inventory,
            True,
        )

    def test_frozen_module_rename_reports_pass(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_cli_passes_complete_matching_evidence(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--baseline",
                str(FIXTURES / "baseline-v1.json"),
                "--candidate",
                str(FIXTURES / "candidate-v1.json"),
                "--inventory",
                str(FIXTURES / "inventory-v1.json"),
                "--require-all",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("3 matched cases", completed.stdout)

    def test_omitted_register_reports_the_case_surface_and_key(self) -> None:
        candidate = copy.deepcopy(self.candidate)
        del candidate["results"][0]["observation"]["durableState"]["register.total"]
        errors = self.errors(candidate=candidate)
        self.assertTrue(any("aggregate/order/prefix-1" in error and "register.total" in error for error in errors), errors)

    def test_omitted_workflow_surface_is_not_hidden_by_a_passing_row(self) -> None:
        candidate = copy.deepcopy(self.candidate)
        candidate["selectedSurfaces"] = [
            surface for surface in candidate["selectedSurfaces"] if surface["kind"] != "workflow-journal"
        ]
        errors = self.errors(candidate=candidate)
        self.assertTrue(any("workflow/checkout/step-charge" in error and "workflow-journal" in error for error in errors), errors)

    def test_stale_build_identity_fails(self) -> None:
        candidate = copy.deepcopy(self.candidate)
        candidate["buildPair"]["candidate"]["dependencyPlanHash"] = "stale-plan"
        self.assertIn("candidate buildPair does not match inventory", self.errors(candidate=candidate))

    def test_changed_corpus_hash_fails(self) -> None:
        candidate = copy.deepcopy(self.candidate)
        candidate["corpusHash"] = "different-corpus"
        self.assertIn("baseline and candidate corpus hashes differ", self.errors(candidate=candidate))

    def test_two_empty_observations_do_not_pass(self) -> None:
        baseline = copy.deepcopy(self.baseline)
        candidate = copy.deepcopy(self.candidate)
        empty = {"durableState": {}, "continuations": [], "durableIdentities": {}, "freshAllocations": []}
        baseline["results"][0]["observation"] = empty
        candidate["results"][0]["observation"] = empty
        errors = self.errors(baseline=baseline, candidate=candidate)
        self.assertTrue(any("empty observation" in error for error in errors), errors)

    def test_missing_independent_source_fails_require_all(self) -> None:
        inventory = copy.deepcopy(self.inventory)
        inventory["contributions"] = inventory["contributions"][:-1]
        errors = self.errors(inventory=inventory)
        self.assertTrue(any("application-owned-obligations" in error for error in errors), errors)

    def test_unsupported_contract_versions_fail(self) -> None:
        inventory = copy.deepcopy(self.inventory)
        baseline = copy.deepcopy(self.baseline)
        inventory["inventoryVersion"] = "future"
        baseline["reportVersion"] = "future"
        errors = self.errors(inventory=inventory, baseline=baseline)
        self.assertTrue(any("unsupported inventory version" in error for error in errors), errors)
        self.assertTrue(any("unsupported version" in error for error in errors), errors)

    def test_duplicate_json_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"reportVersion":"one","reportVersion":"two"}', encoding="utf-8")
            with self.assertRaises(CHECKER.ContractError):
                CHECKER.load_json(path)


if __name__ == "__main__":
    unittest.main()
