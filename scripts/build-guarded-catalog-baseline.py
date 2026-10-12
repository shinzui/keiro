#!/usr/bin/env python3
"""Run in nix develop to build the shared harness against original Keiro.

Production library files stay at the recorded revision. Only the benchmark
stanza, shared fixture/harness and generic test-resource helper are overlaid.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
from datetime import datetime, timezone

ORIGINAL = "ad78efae0d21d849c8106eac73df0f8bb5719e1f"
ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worktree", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    worktree = args.worktree.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = output / "enhanced-environment.json"
    if manifest.exists():
        raise SystemExit("manifest already exists; choose a new evidence directory")
    if not worktree.exists():
        subprocess.run(["git", "worktree", "add", "--detach", str(worktree), ORIGINAL], cwd=ROOT, check=True)
    if run("git", "rev-parse", "HEAD", cwd=worktree) != ORIGINAL:
        raise SystemExit("worktree is not at the original library revision")
    files = [
        "keiro/bench/GuardedCatalogWorkload.hs",
        "keiro/bench/GuardedCatalogBaselineMain.hs",
        "keiro/test/GuardedCatalogFixture.hs",
        "keiro-test-support/src/Keiro/Test/Postgres.hs",
    ]
    for name in files:
        destination = worktree / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, destination)
    original_cabal = run("git", "show", f"{ORIGINAL}:keiro/keiro.cabal") + "\n"
    prefix, stanza = original_cabal.split("benchmark keiro-bench\n", 1)
    stanza = stanza.replace("hs-source-dirs: bench", "hs-source-dirs: bench, test", 1)
    stanza = stanza.replace("main-is: Main.hs", "main-is: GuardedCatalogBaselineMain.hs", 1)
    beginning, modules = stanza.split("  other-modules:\n", 1)
    _, ending = modules.split("  ghc-options:", 1)
    stanza = beginning + "  other-modules:\n    GuardedCatalogFixture\n    GuardedCatalogWorkload\n\n  ghc-options:" + ending
    if "    vector " not in stanza:
        stanza = stanza.replace("    uuid ", "    vector >=0.13 && <0.14,\n    uuid ")
    (worktree / "keiro/keiro.cabal").write_text(prefix + "benchmark keiro-bench\n" + stanza)
    freeze = ROOT / "cabal.project.freeze"
    if freeze.exists():
        shutil.copyfile(freeze, worktree / "cabal.project.freeze")
    subprocess.run(["cabal", "build", "keiro:bench:keiro-bench"], cwd=worktree, check=True)
    executable = Path(run("cabal", "list-bin", "keiro:bench:keiro-bench", cwd=worktree))
    # Retain only a binary returned from this project's build directory.
    executable.relative_to(worktree / "dist-newstyle")
    retained = output / "ordinary-baseline"
    shutil.copyfile(executable, retained)
    retained.chmod(0o755)
    plan = json.loads((worktree / "dist-newstyle/cache/plan.json").read_text())
    manifest.write_text(json.dumps({
        "originalLibraryCommit": ORIGINAL,
        "harnessCommit": run("git", "rev-parse", "HEAD"),
        "harnessFiles": {name: digest(ROOT / name) for name in files},
        "workloadSha256": digest(ROOT / files[0]),
        "fixtureSha256": digest(ROOT / files[2]),
        "retainedExecutable": str(retained),
        "sha256": digest(retained),
        "compiler": run("ghc", "--numeric-version"),
        "cabal": run("cabal", "--numeric-version"),
        "buildOptions": "GHC -O1; runtime +RTS -N2 -RTS; pool size 10",
        "freezeSha256": digest(freeze) if freeze.exists() else None,
        "dependencies": sorted({(p.get("pkg-name"), p.get("pkg-version")) for p in plan["install-plan"]}),
        "machine": platform.platform(),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "purpose": "enhanced alternating baseline; initial latency archive remains provenance only",
    }, indent=2) + "\n")
    print(manifest)


if __name__ == "__main__":
    main()
