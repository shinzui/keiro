"""Behavioral controls for release refusal, reuse, isolation and index retries."""

from __future__ import annotations

import json
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_consumer as consumer
import release_workflow as release


class GateControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="keiro-release-control-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release control")
        self.git("config", "user.email", "release-control@example.invalid")
        (self.root / "scripts").mkdir()
        (self.root / "justfile").write_text(
            '_verify:\n    @echo correctness >> calls\n    @test ! -f refuse-correctness\n')
        bench = self.root / "scripts/bench-regression.sh"
        bench.write_text('#!/bin/sh\necho "$1" >> calls\ntest ! -f "refuse-$1"\n')
        bench.chmod(0o755)
        (self.root / "baseline.csv").write_text("accepted baseline\n")
        self.git("add", ".")
        self.git("commit", "-qm", "test: seed release control")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True)

    def inputs(self):
        return {"source": release.source_identity(self.root), "plan": "fixed", "toolchain": "fixed", "environment": "fixed"}

    def gate(self, inputs=None, fresh=False):
        return release.Gate(self.root, inputs or self.inputs(), fresh)

    def calls(self):
        path = self.root / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_failed_correctness_starts_no_benchmark(self):
        (self.root / "refuse-correctness").touch()
        gate = self.gate()
        self.assertEqual(gate.execute(), 1)
        self.assertEqual(self.calls(), ["correctness"])
        self.assertFalse(json.loads(gate.path.read_text())["accepted"])

    def test_retry_runs_only_the_failed_guard(self):
        refusal = self.root / "refuse-inbox"
        refusal.touch()
        first = self.gate()
        self.assertEqual(first.execute(), 1)
        self.assertEqual(self.calls(), ["correctness", *release.GUARDS])
        refusal.unlink()
        second = self.gate()
        self.assertEqual(second.execute(), 0)
        self.assertEqual(self.calls(), ["correctness", *release.GUARDS, "inbox"])
        self.assertTrue(second.manifest["stages"]["correctness"]["reused"])
        self.assertFalse(second.manifest["stages"]["inbox"]["reused"])
        self.assertNotEqual(first.path, second.path)

    def test_fresh_forces_every_stage(self):
        self.assertEqual(self.gate().execute(), 0)
        self.assertEqual(self.gate(fresh=True).execute(), 0)
        self.assertEqual(len(self.calls()), 14)

    def test_changed_inputs_invalidate_correctness(self):
        self.assertEqual(self.gate().execute(), 0)
        for key in ("plan", "toolchain", "environment"):
            inputs = self.inputs()
            inputs[key] = "changed-" + key
            gate = self.gate(inputs)
            self.assertEqual(gate.execute(), 0)
            self.assertFalse(gate.manifest["stages"]["correctness"]["reused"])
        (self.root / "baseline.csv").write_text("different baseline\n")
        changed = self.gate()
        self.assertEqual(changed.execute(), 0)
        self.assertFalse(changed.manifest["stages"]["correctness"]["reused"])

    def test_tampered_log_is_not_reused(self):
        first = self.gate()
        self.assertEqual(first.execute(), 0)
        receipt = json.loads((self.root / first.manifest["stages"]["correctness"]["receipt"]).read_text())
        (self.root / receipt["log"]).write_text("forged pass\n")
        second = self.gate()
        self.assertEqual(second.execute(), 0)
        self.assertFalse(second.manifest["stages"]["correctness"]["reused"])

    def test_interrupted_latest_attempt_supersedes_old_pass(self):
        first = self.gate()
        self.assertEqual(first.execute(), 0)
        receipt = json.loads((self.root / first.manifest["stages"]["correctness"]["receipt"]).read_text())
        receipt.update(status=None, started=time.time() + 1)
        release.atomic_json(first.directory / "interrupted-correctness.json", receipt)
        second = self.gate()
        self.assertEqual(second.execute(), 0)
        self.assertFalse(second.manifest["stages"]["correctness"]["reused"])

    def test_new_failure_cannot_fall_back_to_old_pass(self):
        self.assertEqual(self.gate().execute(), 0)
        (self.root / "refuse-correctness").touch()
        self.assertEqual(self.gate(fresh=True).execute(), 1)
        self.assertEqual(self.gate().execute(), 1)

    def test_expired_missing_and_schema_mismatched_receipts_refuse(self):
        gate = self.gate()
        self.assertEqual(gate.execute(), 0)
        receipt = json.loads((self.root / gate.manifest["stages"]["correctness"]["receipt"]).read_text())
        expected = receipt["identity"]
        self.assertTrue(release.reusable(receipt, expected, self.root))
        self.assertFalse(release.reusable(receipt, expected, self.root, receipt["finished"] + release.MAX_AGE + 1))
        self.assertFalse(release.reusable({**receipt, "schema": -1}, expected, self.root))
        self.assertFalse(release.reusable({**receipt, "log": "missing.log"}, expected, self.root))
        self.assertFalse(release.reusable({}, expected, self.root))

    def test_evidence_and_plan_notes_preserve_source_identity(self):
        initial = release.source_identity(self.root)
        for name in ("docs/plans/999-next-release.md", "docs/masterplans/999-next-initiative.md"):
            path = self.root / name
            path.parent.mkdir(parents=True)
            path.write_text("execution notes\n")
            self.git("add", name)
            self.assertEqual(initial, release.source_identity(self.root))
        evidence = self.root / release.EVIDENCE / "result.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text("{}\n")
        self.git("add", str(evidence.relative_to(self.root)))
        self.assertEqual(initial, release.source_identity(self.root))

    def test_policy_documents_and_code_inside_plan_directories_are_inputs(self):
        initial = release.source_identity(self.root)
        for name in ("docs/adr/policy.md", "docs/plans/fixture.hs"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("material input\n")
            self.git("add", name)
            self.assertNotEqual(initial, release.source_identity(self.root))
            self.git("reset", "-q", "HEAD", "--", name)

    def test_interrupted_gate_has_an_unaccepted_manifest(self):
        gate = self.gate()
        manifest = json.loads(gate.path.read_text())
        self.assertFalse(manifest.get("accepted", False))
        with self.assertRaisesRegex(RuntimeError, "not accepted"):
            release.check_manifest(gate.path, self.inputs(), self.root)

    def test_uncommitted_candidate_refuses(self):
        (self.root / "baseline.csv").write_text("uncommitted change\n")
        with self.assertRaisesRegex(RuntimeError, "Commit the candidate"):
            release.require_clean(self.root)

    def test_dirty_corpus_refuses_before_any_compilation(self):
        corpus = self.root / "keiro-dsl/test/Main.hs"
        corpus.parent.mkdir(parents=True)
        corpus.write_text("uncommitted edit\n")
        with patch.object(release, "run") as command, patch.object(release, "version", return_value="0.22.0.0"):
            with self.assertRaisesRegex(RuntimeError, "before compiling"):
                release.prepare(self.root)
            command.assert_not_called()

    def test_blueprint_on_feature_branch_does_not_count_as_published(self):
        blueprint = self.root / "blueprints/example/blueprint.dhall"
        blueprint.parent.mkdir(parents=True)
        blueprint.write_text("published payload\n")
        self.git("add", str(blueprint.relative_to(self.root)))
        self.git("commit", "-qm", "test: publish blueprint")
        origin = self.root / ".git/control-origin.git"
        self.git("init", "--bare", "-q", str(origin))
        self.git("--git-dir", str(origin), "symbolic-ref", "HEAD", "refs/heads/published")
        self.git("remote", "add", "origin", str(origin))
        self.git("push", "-q", "origin", "HEAD:published")
        release.published_blueprint(self.root, "blueprints/example")
        blueprint.write_text("feature-only payload\n")
        self.git("add", str(blueprint.relative_to(self.root)))
        self.git("commit", "-qm", "test: feature-only prerequisite")
        self.git("push", "-q", "origin", "HEAD:feature")
        with self.assertRaisesRegex(RuntimeError, "published default branch"):
            release.published_blueprint(self.root, "blueprints/example")

    def test_concurrent_writer_refuses(self):
        script = Path(release.__file__).resolve()
        code = (f"import sys; sys.path.insert(0, {str(script.parent)!r}); "
                f"from release_workflow import workspace_lock; from pathlib import Path; "
                f"lock=workspace_lock(Path({str(self.root)!r})); lock.__enter__()")
        with release.workspace_lock(self.root):
            result = subprocess.run([sys.executable, "-c", code], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Another release/build writer", result.stderr)
        with release.workspace_lock(self.root):
            pass

    def test_manifest_refuses_later_failed_attempt(self):
        first = self.gate()
        self.assertEqual(first.execute(), 0)
        release.check_manifest(first.path, self.inputs(), self.root)
        (self.root / "refuse-correctness").touch()
        self.assertEqual(self.gate(fresh=True).execute(), 1)
        with self.assertRaisesRegex(RuntimeError, "later correctness attempt"):
            release.check_manifest(first.path, self.inputs(), self.root)

    def test_mutation_during_successful_command_refuses_acceptance(self):
        (self.root / "justfile").write_text('_verify:\n    @echo mutated >> baseline.csv\n')
        gate = self.gate()
        self.assertEqual(gate.execute(), 1)
        self.assertEqual(gate.manifest["stages"]["correctness"]["status"], 1)

    def test_runtime_flags_and_database_url_invalidate_identity_but_nix_scratch_does_not(self):
        config = self.root / "cabal.config"
        config.write_text("repository hackage.haskell.org\n")
        def tool_output(args, root):
            return str(config) if args[:2] == ["cabal", "path"] else "fixed-tool-output"
        with patch.object(release, "output", side_effect=tool_output):
            # Exercise real config/environment hashing without toolchain probes.
            with patch.object(release, "source_identity", return_value="fixed-source"):
                original = release.identity(self.root, {"install-plan": []})
                for key in ("CFLAGS", "DATABASE_URL", "KEIRO_RETENTION_REPORT_ONLY", "GHC_OPTIONS"):
                    with self.subTest(key=key), patch.dict(os.environ, {key: "changed"}):
                        self.assertNotEqual(original, release.identity(self.root, {"install-plan": []}))
                with patch.dict(os.environ, {"NIX_BUILD_TOP": "/new/scratch", "NIX_LOG_FD": "99"}):
                    self.assertEqual(original, release.identity(self.root, {"install-plan": []}))


class ConsumerControls(unittest.TestCase):
    def test_database_is_removed_when_migration_fails(self):
        failure = subprocess.CalledProcessError(1, ["migrator"])
        with tempfile.TemporaryDirectory() as scratch, patch.object(consumer.subprocess, "run", side_effect=[None, failure, None]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                consumer.health_check("server", "migrator", Path(scratch), Path(scratch), io.StringIO())
            created = run.call_args_list[0].args[0]
            dropped = run.call_args_list[-1].args[0]
            self.assertEqual(created[0], "createdb")
            self.assertEqual(dropped[0], "dropdb")
            self.assertEqual(created[-1], dropped[-1])
            self.assertTrue(created[-1].startswith("keiro_release_"))

    def test_default_dependency_closure_ignores_unreachable_git_pins(self):
        units = [
            {"id": "root", "pkg-name": "keiro", "type": "configured", "component-name": "lib", "depends": ["dep"]},
            {"id": "dep", "pkg-name": "published", "pkg-version": "1.0", "type": "configured",
             "pkg-src": {"type": "repo-tar", "repo": {"uri": "https://hackage.haskell.org/"}}},
            {"id": "manual-off", "pkg-name": "codd", "pkg-version": "1.0", "type": "configured",
             "pkg-src": {"type": "source-repo"}},
        ]
        self.assertEqual(release.published_dependencies({"install-plan": units}), {("published", "1.0")})
        units[0]["depends"].append("manual-off")
        with self.assertRaisesRegex(RuntimeError, "not a Hackage release"):
            release.published_dependencies({"install-plan": units})

    def plan(self, mode="published"):
        return {"install-plan": [{"type": "configured", "pkg-name": p, "pkg-version": "0.22.0.0",
                                 "pkg-src": {"type": "repo-tar" if mode == "published" else "local-tar",
                                             "repo": {"uri": "https://hackage.haskell.org/"}}}
                                for p in release.PACKAGES]}

    def test_exact_cohort_and_expected_sources_required(self):
        for mode in ("published", "staged"):
            consumer.validate_plan(self.plan(mode), "0.22.0.0", mode)
        for change in ("wrong-version", "local-checkout", "omitted-package", "http-mirror"):
            plan = self.plan()
            if change == "wrong-version":
                plan["install-plan"][0]["pkg-version"] = "0.21.0.0"
            elif change == "local-checkout":
                plan["install-plan"][0]["pkg-src"]["type"] = "local"
            elif change == "omitted-package":
                plan["install-plan"].pop()
            else:
                plan["install-plan"][0]["pkg-src"]["repo"]["uri"] = "http://hackage.haskell.org/"
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                consumer.validate_plan(plan, "0.22.0.0", "published")

    def test_retries_index_solving_with_a_bound(self):
        calls = []
        sleeps = []
        def fail(command, check=True):
            calls.append(command)
            return 1 if "--dry-run" in command else 0
        with self.assertRaisesRegex(RuntimeError, "after 5 attempt"):
            consumer.solve(["cabal"], Path("proof"), "published", fail, sleeps.append)
        self.assertEqual(len(calls), 10)
        self.assertEqual(sleeps, [15] * 4)
        self.assertTrue(all("--dry-run" in c for c in calls if "build" in c))

    def test_staged_solve_is_not_retried(self):
        calls = []
        def fail(command, check=True):
            calls.append(command)
            return 1 if "--dry-run" in command else 0
        with self.assertRaisesRegex(RuntimeError, "after 1 attempt"):
            consumer.solve(["cabal"], Path("proof"), "staged", fail, lambda _: self.fail("unexpected sleep"))
        self.assertEqual(len(calls), 2)

    def test_https_config_replaces_global_configuration(self):
        config = consumer.cabal_config(Path("/tmp/isolated-release"))
        self.assertIn("url: https://hackage.haskell.org/", config)
        self.assertIn("secure: True", config)
        self.assertIn("remote-repo-cache: /tmp/isolated-release/package-cache", config)
        self.assertNotIn("http://", config)


if __name__ == "__main__":
    unittest.main()
