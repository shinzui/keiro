#!/usr/bin/env python3
"""Build exact release archives or Hackage packages in an isolated HTTPS project."""

from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import urllib.request
import uuid

from release_workflow import (
    ROOT, PACKAGES, atomic_json, file_digest, output, require_clean, source_identity,
    version, workspace_lock,
)

ATTEMPTS = 5
INDEX_DELAY = 15


def cabal_config(work):
    # This is a replacement configuration, not a repository appended to the
    # user's global config. No credentials, legacy mirrors or index are copied.
    return ("repository hackage.haskell.org\n"
            "  url: https://hackage.haskell.org/\n"
            "  secure: True\n\n"
            f"remote-repo-cache: {work / 'package-cache'}\n")


def validate_plan(plan, current, mode):
    found = set()
    for package in plan["install-plan"]:
        name = package["pkg-name"]
        source = package.get("pkg-src", {})
        if name in PACKAGES:
            if package["pkg-version"] != current:
                raise RuntimeError(f"Consumer selected wrong version of {name}")
            expected = "local-tar" if mode == "staged" else "repo-tar"
            if source.get("type") != expected:
                raise RuntimeError(f"Consumer selected unexpected source for {name}: {source}")
            found.add(name)
        elif name != "release-consumer" and package["type"] != "pre-existing":
            if source.get("type") != "repo-tar":
                raise RuntimeError(f"External consumer dependency is not from Hackage: {name}")
        if source.get("type") == "repo-tar":
            uri = source.get("repo", {}).get("uri", "")
            if uri != "https://hackage.haskell.org/":
                raise RuntimeError(f"Consumer dependency is not from the secure HTTPS repository: {name}")
    if found != set(PACKAGES):
        raise RuntimeError("Consumer plan omits release packages: " + ", ".join(set(PACKAGES) - found))


def solve(cabal, work, mode, run, sleep=time.sleep):
    # Retry only index refresh/dependency solving. Never retry compilation or
    # runtime failures, which would hide defects behind an index-lag explanation.
    attempts = ATTEMPTS if mode == "published" else 1
    for attempt in range(attempts):
        run(cabal + ["update"])
        result = run(cabal + ["build", "all", "--dry-run"], check=False)
        if result == 0:
            return
        if attempt + 1 < attempts:
            print(f"Waiting for the published cohort in the Hackage index ({attempt + 1}/{attempts}).", flush=True)
            sleep(INDEX_DELAY)
    raise RuntimeError(f"Consumer dependency solve failed after {attempts} attempt(s); see {work / 'proof.log'}")


def health_check(executable, migrator, work, root, log):
    database = "keiro_release_" + uuid.uuid4().hex[:16]
    socket = str(root / "db")
    user = os.environ.get("PGUSER", getpass.getuser())
    # Only touch a newly allocated scratch DB on the local project cluster.
    quote = lambda value: "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
    connection = f"host={quote(socket)} dbname={database} user={quote(user)}"
    subprocess.run(["createdb", "-h", socket, "-U", user, database], check=True)
    process = None
    try:
        subprocess.run([migrator, "up", "--database-url", connection], cwd=work, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (work / "server.stderr.log").open("w") as errors:
            process = subprocess.Popen([executable], cwd=work, env={**os.environ, "DATABASE_URL": connection},
                                       stdout=subprocess.PIPE, stderr=errors, text=True)
            deadline = time.monotonic() + 45
            port = None
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Consumer server exited before listening")
                if select.select([process.stdout], [], [], 1)[0]:
                    line = process.stdout.readline().strip()
                    if line.isdigit():
                        port = int(line)
                        break
            if port is None:
                raise RuntimeError("Consumer server did not publish its port within 45 seconds")
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/keiro/health", timeout=10) as response:
                health = json.load(response)
            if health != {"status": "ok", "schema_drift": [], "mutations_enabled": False}:
                raise RuntimeError(f"Unexpected consumer health: {health}")
            print(json.dumps(health, sort_keys=True), flush=True)
            log.write(json.dumps(health, sort_keys=True) + "\n")
            return health
    finally:
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        if process is not None:
            process.stdout.close()
        subprocess.run(["dropdb", "-h", socket, "-U", user, database], check=True)


def consumer(mode, root=ROOT):
    require_clean(root)
    current = version(root)
    source = source_identity(root)
    work = root / "dist-release" / current / ("consumer-" + mode)
    work.mkdir(parents=True, exist_ok=True)
    # A previous success must not survive a failed or interrupted retry.
    result_path = work / "result.json"
    atomic_json(result_path, {"mode": mode, "version": current, "status": "running", "source": source})
    (work / "cabal.config").write_text(cabal_config(work))
    dependencies = ",\n    ".join(f"{p} =={current}" for p in PACKAGES)
    (work / "release-consumer.cabal").write_text(
        "cabal-version: 3.4\nname: release-consumer\nversion: 0.1.0.0\nbuild-type: Simple\n\n"
        "executable release-consumer\n  main-is: Main.hs\n  default-language: GHC2024\n"
        "  default-extensions: OverloadedStrings OverloadedRecordDot\n  ghc-options: -threaded\n"
        "  build-depends: base >=4.21 && <5, async, text, kiroku-store,\n    " + dependencies + "\n")
    (work / "Main.hs").write_bytes((root / "scripts/release-consumer/Main.hs").read_bytes())
    # These files are generated only by us; remove project overrides left by
    # earlier manual experiments, rather than letting them change the proof.
    for name in ("cabal.project.local", "cabal.project.freeze"):
        if (work / name).exists():
            raise RuntimeError(f"Remove the unexpected isolated consumer override before retrying: {work / name}")
    package_lines = ["packages: ."]
    archives = {}
    if mode == "staged":
        archive_root = work.parent
        inventory = json.loads((archive_root / "artifacts.json").read_text())
        if inventory["source"] != source or inventory["version"] != current:
            raise RuntimeError("Staged artifacts do not match this candidate; rerun release-artifacts")
        for package in PACKAGES:
            archive = archive_root / f"{package}-{current}.tar.gz"
            checksum = file_digest(archive)
            if checksum != inventory["sha256"].get(archive.name):
                raise RuntimeError(f"Staged archive checksum mismatch: {archive.name}")
            archives[archive.name] = checksum
            package_lines.append("  " + str(archive))
    (work / "cabal.project").write_text("\n".join(package_lines) + "\n")
    cabal = ["cabal", "--config-file=" + str(work / "cabal.config")]
    # The workspace migrator is explicitly identified; consumer libraries and
    # the HTTP executable must still come exclusively from the audited plan.
    migrator = output(["cabal", "list-bin", "keiro-migrations:exe:keiro-migrate"], root)
    with (work / "proof.log").open("w") as log:
        def run(command, check=True):
            print("+ " + " ".join(command), flush=True)
            timeout = 120 if "update" in command or "--dry-run" in command else None
            result = subprocess.run(command, cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            log.flush()
            if check and result.returncode:
                raise RuntimeError(f"Consumer command failed ({result.returncode}); see {work / 'proof.log'}")
            return result.returncode
        solve(cabal, work, mode, run)
        plan = json.loads((work / "dist-newstyle/cache/plan.json").read_text())
        validate_plan(plan, current, mode)
        run(cabal + ["build", "all"])
        executable = subprocess.check_output(cabal + ["list-bin", "exe:release-consumer"], cwd=work, text=True).strip()
        health = health_check(executable, migrator, work, root, log)
    if source_identity(root) != source:
        raise RuntimeError("Candidate changed during consumer validation")
    atomic_json(result_path, {"mode": mode, "version": current, "status": "passed", "source": source,
                              "archives": archives, "plan_sha256": file_digest(work / "dist-newstyle/cache/plan.json"),
                              "log_sha256": file_digest(work / "proof.log"), "health": health,
                              "migrator": migrator, "finished": time.time()})
    print(f"CONSUMER({mode})=PASSED {result_path.relative_to(root)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("staged", "published"))
    args = parser.parse_args()
    if not os.environ.get("IN_NIX_SHELL"):
        parser.error("Use nix develop -c just release-consumer " + args.mode)
    with workspace_lock():
        consumer(args.mode)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"release consumer: {error}", file=sys.stderr)
        raise SystemExit(1)
