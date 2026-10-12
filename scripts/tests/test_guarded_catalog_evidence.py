"""Protect performance reporting from incomplete or missing retained evidence."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "summarize-guarded-catalog-evidence.py"
SPEC = importlib.util.spec_from_file_location("guarded_evidence", SCRIPT)
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / "manifest.json").write_text('{"mode":"compare"}')

    def test_ratios_preserve_each_metric_and_spread(self):
        report = {"ratios": [[0.8, 1.3, 1.4], [1.2, 1.1, 1.6], [1.0, 1.2, 1.5],
                             [0.9, 1.0, 1.3], [1.1, 1.4, 1.7]]}
        result = EVIDENCE.ratio_summary(report)
        self.assertEqual(result["throughput"], {"count": 5, "median": 1.0, "minimum": 0.8, "maximum": 1.2})
        self.assertEqual(result["p95"]["median"], 1.2)
        self.assertEqual(result["p99"]["median"], 1.5)

    def test_requires_observed_durability_and_vacuum_settings(self):
        settings = dict.fromkeys(["fsync", "synchronous_commit", "full_page_writes", "autovacuum"], "on")
        self.assertTrue(EVIDENCE.durability_verified({"databaseSettings": settings}))
        self.assertFalse(EVIDENCE.durability_verified({}))
        for name in settings:
            self.assertFalse(EVIDENCE.durability_verified({"databaseSettings": {**settings, name: "off"}}))

    def test_empty_run_has_190_missing_comparisons(self):
        result = EVIDENCE.matrix_inventory(self.directory, {})
        self.assertFalse(result["complete"])
        self.assertEqual(result["expectedReports"], 190)
        self.assertEqual(len(result["missingReports"]), 190)

    def test_passing_report_without_raw_pairs_is_incomplete(self):
        name = "refactor-10000-1-1-False-0-0-True-Nothing-report.json"
        result = EVIDENCE.matrix_inventory(self.directory, {name: {"pass": True, "ratios": [[1, 1, 1]] * 5}})
        self.assertFalse(result["complete"])
        self.assertEqual(result["presentReports"], 1)
        self.assertEqual(len(result["missingSamples"]), 10)

    def test_complete_matrix_requires_both_rates_states_and_storage(self):
        reports = {}
        # Build the complete fixture from the published workload dimensions.
        for size in [10000, 1000000]:
            for connections in [1, 8]:
                for batch in [1, 4]:
                    for worker in [False, True]:
                        base = f"{size}-{connections}-{batch}-{worker}"
                        configs = [("refactor", 0, 0, True), ("empty", 100, 0, True), ("miss", 100, 0, True)]
                        configs += [("hit", 100, 100, spread) for spread in [False, True]]
                        configs += [("mixed", 20, duplicates, spread) for duplicates in [0, 50, 100] for spread in [False, True]]
                        for kind, guard, duplicates, spread in configs:
                            reports[f"{kind}-{base}-{guard}-{duplicates}-{spread}-Nothing-report.json"] = {"pass": True, "ratios": [[1, 1, 1]] * 5}
        for worker in [False, True]:
            (self.directory / f"capacity-{worker}-rates.json").write_text('{"fixedCapacity":400}')
            for rate in [200.0, 320.0]:
                for duplicates in [0, 50, 100]:
                    reports[f"fixed-arrival-1000000-8-4-{worker}-20-{duplicates}-True-{rate}-report.json"] = {"pass": True, "ratios": [[1, 1, 1]] * 5}
            reports[f"sustained-{worker}-report.json"] = {"latencyPass": True}
        for name in reports:
            stem = name.removesuffix("-report.json")
            if name.startswith("sustained-"):
                for label in ["control", "duplicates"]:
                    (self.directory / f"{stem}-{label}.json.gz").touch()
                    (self.directory / f"{stem}-{label}-storage.jsonl").touch()
            else:
                for pair in range(1, 6):
                    for side in ["control", "candidate"]:
                        (self.directory / f"{stem}-{pair}-{side}.json.gz").touch()
        self.assertEqual(len(reports), 190)
        self.assertTrue(EVIDENCE.matrix_inventory(self.directory, reports)["complete"])
        (self.directory / "sustained-True-duplicates-storage.jsonl").unlink()
        self.assertFalse(EVIDENCE.matrix_inventory(self.directory, reports)["complete"])

    def test_require_complete_exits_nonzero_and_records_incompleteness(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.directory), "--require-complete"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads((self.directory / "aggregate-report.json").read_text())
        self.assertEqual(report["performanceAcceptance"], "incomplete")
        self.assertEqual(report["failedReports"], [])


if __name__ == "__main__":
    unittest.main()
