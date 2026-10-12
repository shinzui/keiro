#!/usr/bin/env python3
"""Run the fixed catalog matrix in nix develop, retaining host contamination.

Build both binaries first. This command measures only; it never builds, changes
budgets, retries failed comparisons, or stops another contributor's process.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def command(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def host_snapshot():
    processes = command("ps", "-eo", "pid,ppid,pcpu,args")
    blockers = []
    retained = ["PID PPID CPU EXECUTABLE"]
    for line in processes.splitlines()[1:]:
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        executable = fields[3].split()[0]
        # Command arguments may contain another contributor's credentials.
        # Retain executable identity and resource use, never their arguments.
        observation = " ".join(fields[:3] + [executable])
        retained.append(observation)
        name = Path(executable).name.lstrip(".").removesuffix("-wrapped")
        if (name in {"cabal", "cargo", "rustc", "gcc", "cc", "clang", "clang++"}
                or name == "ghc" or name.startswith("ghc-")
                or (name == "nix-store" and "--serve" in fields[3])
                or name.endswith(("-test", "-tests"))
                or (executable.startswith("/build/") and "test" in name)):
            blockers.append(observation)
    return {"at": datetime.now(timezone.utc).isoformat(),
            "load": os.getloadavg(), "processes": "\n".join(retained), "blockers": blockers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = args.baseline.resolve()
    output = args.output.resolve()
    if output.exists():
        raise SystemExit("output already exists; choose a new directory")
    if not os.environ.get("IN_NIX_SHELL"):
        raise SystemExit("run this command in the project's Nix development shell")
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    executable = Path(command("cabal", "list-bin", "keiro:bench:keiro-bench"))
    executable.relative_to(ROOT / "dist-newstyle")
    manifest = json.loads((baseline / "enhanced-environment.json").read_text())
    plan = json.loads((ROOT / "dist-newstyle/cache/plan.json").read_text())
    dependencies = sorted({(p.get("pkg-name"), p.get("pkg-version"))
                           for p in plan["install-plan"]})
    if dependencies != sorted(map(tuple, manifest["dependencies"])):
        raise SystemExit("baseline/candidate dependency inventories differ; rebuild with one freeze file")
    compiler = command("ghc", "--numeric-version")
    if compiler != manifest["compiler"] or plan["compiler-id"] != "ghc-" + compiler:
        raise SystemExit("baseline/candidate compilers differ")
    for name, expected in manifest["harnessFiles"].items():
        if digest(ROOT / name) != expected:
            raise SystemExit(f"shared harness digest mismatch: {name}")
    baseline_executable = Path(manifest["retainedExecutable"])
    if digest(baseline_executable) != manifest["sha256"]:
        raise SystemExit("retained baseline executable digest mismatch")
    output.mkdir(parents=True)
    identity = {"candidateCommit": command("git", "rev-parse", "HEAD"),
                "candidateExecutable": str(executable), "candidateSha256": digest(executable),
                "originalLibraryCommit": manifest["originalLibraryCommit"],
                "baselineSha256": manifest["sha256"], "dependencies": dependencies,
                "compiler": compiler, "platform": platform.platform(),
                "runtimeOptions": "+RTS -N2 -RTS", "hostSampleSeconds": 5,
                "isolation": "host observation; no exclusive cell lease",
                "at": datetime.now(timezone.utc).isoformat()}
    (output / "candidate-environment.json").write_text(json.dumps(identity, indent=2) + "\n")
    environment = dict(os.environ, KEIRO_GUARDED_CATALOG_EVIDENCE="compare",
                       KEIRO_GUARDED_CATALOG_BASELINE=str(baseline),
                       KEIRO_GUARDED_CATALOG_OUTPUT=str(output))
    contaminated = False
    process = None
    with (output / "host-activity.jsonl").open("w") as hosts, (output / "comparison.log").open("w") as log:
        try:
            # A bounded preflight catches workloads already using the builder.
            for _ in range(6):
                snapshot = host_snapshot()
                hosts.write(json.dumps(snapshot) + "\n")
                hosts.flush()
                if snapshot["blockers"]:
                    raise RuntimeError("competing build/test detected before measurement")
                time.sleep(5)
            process = subprocess.Popen([str(executable), "+RTS", "-N2", "-RTS"],
                                       cwd=ROOT / "keiro", env=environment,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            while process.poll() is None:
                snapshot = host_snapshot()
                hosts.write(json.dumps(snapshot) + "\n")
                hosts.flush()
                if snapshot["blockers"]:
                    contaminated = True
                    os.killpg(process.pid, signal.SIGINT)
                    break
                time.sleep(5)
            try:
                exit_code = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                exit_code = process.wait(timeout=30)
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                process.wait(timeout=30)
    (output / "execution.json").write_text(json.dumps({"exitCode": exit_code,
                "contaminated": contaminated, "finishedAt": datetime.now(timezone.utc).isoformat()}, indent=2) + "\n")
    summary = subprocess.run(["python3", str(ROOT / "scripts/summarize-guarded-catalog-evidence.py"),
                              str(output), "--require-complete"], cwd=ROOT)
    raise SystemExit(2 if contaminated else exit_code if exit_code else summary.returncode)


if __name__ == "__main__":
    main()
