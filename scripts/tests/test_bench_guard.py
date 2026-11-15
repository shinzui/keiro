"""Release acceptance controls: environment drift is not a code regression."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bench_guard as guard


class AcceptanceControls(unittest.TestCase):
    def exercise_guard(self, candidate_mean, reference_mean, case_count=1, initial_timeout=False,
                       extra_reference_case=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        baseline = root / "keiro/bench/baseline-inbox.csv"
        baseline.parent.mkdir(parents=True)
        names = ["All.inbox.case" + (str(i) if i else "") for i in range(case_count)]
        baseline.write_text("Name,Mean (ps),2*Stdev (ps)\n" + "".join(f"{name},60,1\n" for name in names))
        original = baseline.read_bytes()
        candidate = root / "candidate"
        candidate.write_text("candidate executable")
        cache = root / "reference"
        cache.mkdir()
        reference = cache / "binary"
        reference.write_text("reference executable")
        plan = cache / "dist-newstyle/cache/plan.json"
        plan.parent.mkdir(parents=True)
        plan.write_text("{}")
        (cache / "build.log").write_text("trusted build")

        def measure(binary, cwd, pattern, target, stem, **kwargs):
            mean = candidate_mean if binary == candidate else reference_mean
            measured_names = names + (["All.inbox.extra"] if extra_reference_case else [])
            if stem == "candidate":
                self.assertEqual(kwargs["timeout_inventory"], set(measured_names))
                self.assertEqual(kwargs["recoverable_names"], set(names))
            values = {name: guard.Estimate(mean, 1) for name in measured_names
                      if not (initial_timeout and stem == "candidate" and name == names[0])}
            (target / (stem + ".csv")).write_text(
                "Name,Mean (ps),2*Stdev (ps)\n" + "".join(f"{name},{mean},1\n" for name in values))
            (target / (stem + ".log")).write_text("complete benchmark")
            (target / (stem + "-command.json")).write_text(json.dumps({"status": 0 if values else 1}))
            return values

        target = root / "evidence"
        metadata = {"binary_sha256": guard.sha(reference)}
        with patch.object(guard, "ROOT", root), patch.object(guard, "environment", return_value={}), \
                patch.object(guard, "run", return_value=0), patch.object(guard, "output", return_value=str(candidate)), \
                patch.object(guard, "reference_binary", return_value=(cache, reference, metadata)), \
                patch.object(guard, "measure", side_effect=measure):
            status = guard.guard("inbox", target)
        self.assertEqual(baseline.read_bytes(), original)
        return status, json.loads((target / "result.json").read_text()), target

    def test_whole_guard_accepts_host_drift_without_rewriting_baselines(self):
        status, result, _ = self.exercise_guard(100, 100)
        self.assertEqual(status, 0)
        case = result["cases"]["All.inbox.case"]
        self.assertGreater(case["historical_ratio"], 1.25)
        self.assertEqual(case["ratio"], 1)

    def test_whole_guard_rejects_added_cost_and_retains_both_confirmations(self):
        status, result, target = self.exercise_guard(160, 100)
        self.assertEqual(status, 1)
        case = result["cases"]["All.inbox.case"]
        self.assertEqual(case["status"], "regression")
        self.assertEqual(len(case["confirmation"]), 2)
        self.assertEqual(len(list(target.glob("confirm-*.csv"))), 4)

    def test_multiple_flagged_cases_share_four_confirmation_processes(self):
        status, result, target = self.exercise_guard(160, 100, case_count=3)
        self.assertEqual(status, 1)
        self.assertEqual(len(list(target.glob("confirm-*.csv"))), 4)
        self.assertTrue(all(case["status"] == "regression" for case in result["cases"].values()))

    def test_initial_timeout_requires_two_complete_passing_confirmations(self):
        status, result, _ = self.exercise_guard(100, 100, initial_timeout=True)
        self.assertEqual(status, 0)
        case = result["cases"]["All.inbox.case"]
        self.assertIn("timed out", case["reason"])
        self.assertEqual([p["status"] for p in case["confirmation"]], ["passed", "passed"])

    def test_timeout_inventory_includes_reference_cases_without_historical_budgets(self):
        status, result, _ = self.exercise_guard(100, 100, initial_timeout=True, extra_reference_case=True)
        self.assertEqual(status, 0)
        self.assertEqual(len(result["cases"]), 1)
        self.assertEqual(len(result["cases"]["All.inbox.case"]["confirmation"]), 2)

    def test_only_explicit_timeout_failures_can_supply_partial_measurements(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            def timeout_run(*args, **kwargs):
                (target / "partial.csv").write_text("Name,Mean (ps),2*Stdev (ps)\n")
                return 1
            for transcript, permitted in (("TIMEOUT\nTimed out after 10s\n1 out of 1 tests failed", True),
                                          ("FAIL\nfixture assertion failed\n1 out of 1 tests failed", False),
                                          ("TIMEOUT\nTimed out after 10s\nFAIL\n2 out of 2 tests failed", False)):
                (target / "partial.log").write_text(transcript)
                with patch.object(guard, "run", side_effect=timeout_run):
                    if permitted:
                        self.assertEqual(guard.measure("binary", target, "inbox", target, "partial", allow_timeouts=True, timeout_inventory={"case"}), {})
                    else:
                        with self.assertRaises(RuntimeError):
                            guard.measure("binary", target, "inbox", target, "partial", allow_timeouts=True, timeout_inventory={"case"})
            (target / "partial.log").write_text("TIMEOUT\nTimed out after 10s\n1 out of 2 tests failed")
            with patch.object(guard, "run", side_effect=timeout_run), self.assertRaises(RuntimeError):
                guard.measure("binary", target, "inbox", target, "partial", allow_timeouts=True, timeout_inventory={"case"})
            (target / "partial.log").write_text("TIMEOUT\nTimed out after 10s\n1 out of 1 tests failed")
            with patch.object(guard, "run", side_effect=timeout_run), self.assertRaises(RuntimeError):
                guard.measure("binary", target, "inbox", target, "partial", allow_timeouts=True,
                              timeout_inventory={"extra"}, recoverable_names={"historical"})

    def test_same_environment_comparison_accepts_common_historical_drift(self):
        # Both are far above the old 16us CSV, but the candidate adds no cost.
        result = guard.compare(guard.Estimate(23.05, 1), guard.Estimate(23.43, 1))
        self.assertEqual(result["status"], "passed")
        self.assertLess(result["upper"], 1.25)

    def test_excess_candidate_cost_is_still_rejected(self):
        result = guard.compare(guard.Estimate(150, 2), guard.Estimate(100, 2))
        self.assertEqual(result["status"], "regression")
        self.assertGreater(result["lower"], 1.25)

    def test_noise_crossing_the_ceiling_is_inconclusive(self):
        self.assertEqual(guard.compare(guard.Estimate(127, 20), guard.Estimate(100, 10))["status"],
                         "inconclusive")

    def test_exact_original_ceiling_is_preserved(self):
        self.assertEqual(guard.compare(guard.Estimate(125, 0), guard.Estimate(100, 0))["status"], "passed")
        self.assertEqual(guard.compare(guard.Estimate(125.01, 0), guard.Estimate(100, 0))["status"], "regression")

    def test_a_favorable_retry_cannot_erase_another_observation(self):
        for states in ([], ["passed"], ["passed", "inconclusive"], ["passed", "regression"]):
            self.assertEqual(guard.confirmation_status([{"status": s} for s in states]), "inconclusive")
        self.assertEqual(guard.confirmation_status([{"status": "passed"}] * 2), "passed")
        self.assertEqual(guard.confirmation_status([{"status": "regression"}] * 2), "regression")

    def test_incomplete_or_corrupt_reference_cache_is_not_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "reference.csv"
            path.write_text("original")
            metadata = {"key": "same", "finished": 100, "sha256": {path.name: guard.sha(path)}}
            self.assertTrue(guard.valid_cache(metadata, "same", [path], now=101))
            self.assertFalse(guard.valid_cache(metadata, "other", [path], now=101))
            self.assertFalse(guard.valid_cache(metadata, "same", [path], now=100 + guard.MAX_AGE + 1))
            path.write_text("corrupted")
            self.assertFalse(guard.valid_cache(metadata, "same", [path], now=101))

    def test_invalid_estimates_cannot_make_a_guard_green(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "values.csv"
            for mean, spread in (("nan", "1"), ("0", "0"), ("100", "-1")):
                path.write_text(f"Name,Mean (ps),2*Stdev (ps)\ncase,{mean},{spread}\n")
                with self.assertRaises(ValueError):
                    guard.estimates(path)

    def test_confirmation_preserves_existing_within_run_controls(self):
        names = {"All.command.domain.accepted-1", "All.command.control.accepted-1",
                 "All.command.legacy.accepted-1", "All.command.domain.rejected", "All.command.legacy.no-op"}
        self.assertIn('"All.command.control.accepted-1"',
                      guard.confirmation_pattern("All.command.domain.accepted-1", names))
        self.assertIn('"All.command.legacy.no-op"',
                      guard.confirmation_pattern("All.command.domain.rejected", names))

    def test_benchmark_execution_failure_is_not_reclassified_as_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            with patch.object(sys, "argv", ["bench_guard.py", "inbox"]), \
                    patch.dict(guard.os.environ, {"IN_NIX_SHELL": "1", "KEIRO_BENCH_LOCKED": "1", "KEIRO_BENCH_OUTPUT_DIRECTORY": tmp}), \
                    patch.object(guard, "guard", side_effect=RuntimeError("fixture assertion failed")):
                self.assertEqual(guard.main(), 1)
            self.assertEqual(json.loads((target / "result.json").read_text())["status"], "benchmark-error")


if __name__ == "__main__":
    unittest.main()
