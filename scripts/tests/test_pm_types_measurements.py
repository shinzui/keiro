"""Negative controls for the performance acceptance controller."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "pm_types_analysis", Path(__file__).resolve().parents[1] / "analyze-pm-types.py"
)
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class MeasurementAcceptance(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for label in [
            "baseline-disabled", "candidate-disabled", "baseline-capacity",
            "candidate-capacity", "baseline-idle", "candidate-idle", "control-a",
            "control-b", "catalog-idle", "catalog-active", "many-idle", "many-active",
        ]:
            for pair in range(1, 6):
                path = self.root / label / str(pair) / "trial.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(dict(
                    throughput=50, elapsed_seconds=20, p95_us=100, p99_us=150,
                    writer_thread_allocated_bytes_per_operation=1000,
                    offered_ops_per_second=None if "capacity" in label else 50,
                    poll_success=80 if label.endswith("active") else 0,
                    poll_failure=0,
                    resources_after_clients=dict(views=0, connections=0, wake_pump=False),
                    samples_wait_schedule_claim_resume_timer_us_writer_bytes=[[0, 25, 25, 25, 25, 1000]] * 1000,
                )))

    def edit(self, label, pair, **changes):
        path = self.root / label / str(pair) / "trial.json"
        sample = json.loads(path.read_text())
        sample.update(changes)
        path.write_text(json.dumps(sample))

    def run_analysis(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return analysis.analyze(self.root, 5)

    def test_equal_controls_pass(self):
        self.assertEqual(self.run_analysis(), 0)

    def test_small_supported_degradation_is_refused(self):
        for pair in range(1, 6):
            self.edit("catalog-active", pair, p95_us=100.1)
        self.assertEqual(self.run_analysis(), 1)
        report = json.loads((self.root / "analysis.json").read_text())
        result = next(r for r in report["results"] if r["comparison"] == "catalog-polling" and r["metric"] == "p95_us")
        self.assertEqual(result["status"], "regression")

    def test_wide_intervals_are_inconclusive(self):
        for pair, value in enumerate([97, 98, 100, 102, 103], 1):
            self.edit("candidate-disabled", pair, p95_us=value)
        self.assertEqual(self.run_analysis(), 1)

    def test_lost_polling_and_rejections_are_refused(self):
        self.edit("many-active", 1, poll_success=79)
        with self.assertRaisesRegex(ValueError, "lost polling"):
            self.run_analysis()
        self.edit("many-active", 1, poll_success=80, poll_failure=1)
        with self.assertRaisesRegex(ValueError, "lost polling"):
            self.run_analysis()

    def test_missing_raw_samples_are_refused(self):
        self.edit("candidate-idle", 1, samples_wait_schedule_claim_resume_timer_us_writer_bytes=[])
        with self.assertRaisesRegex(ValueError, "missing"):
            self.run_analysis()

    def test_missing_trial_is_refused(self):
        (self.root / "catalog-idle" / "3" / "trial.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.run_analysis()

    def test_too_few_pairs_are_refused(self):
        with self.assertRaisesRegex(ValueError, "five independent"):
            analysis.analyze(self.root, 4)


if __name__ == "__main__":
    unittest.main()
