#!/usr/bin/env python3
"""Prepare and verify releases without publishing; see the release skill."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import contextlib
import datetime as dt
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path("keiro/bench/results/release-gates")
PACKAGES = (
    "keiro-core", "keiro", "keiro-pgmq", "keiro-migrations",
    "keiro-test-support", "keiro-dsl", "keiro-ops", "keiro-ops-http",
)
GUARDS = ("producer-identity", "outbox", "inbox", "command", "projection", "read-model")
SCHEMA = 1
MAX_AGE = 24 * 60 * 60


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def file_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def output(args, root=ROOT):
    return subprocess.check_output(args, cwd=root, text=True).strip()


def run(args, root=ROOT):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run(args, cwd=root, check=True)


@contextlib.contextmanager
def workspace_lock(root=ROOT):
    """One release workflow writer per workspace."""
    git_dir = Path(output(["git", "rev-parse", "--git-path", "release-workflow.lock"], root))
    if not git_dir.is_absolute():
        git_dir = root / git_dir
    with git_dir.open("a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another release/build writer holds the workspace lock; retry when it finishes.") from None
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def evidence_path(path):
    return path.startswith(EVIDENCE.as_posix() + "/")


def execution_note(path):
    return path.endswith(".md") and path.startswith(("docs/plans/", "docs/masterplans/"))


def excluded_source(path):
    return evidence_path(path) or execution_note(path)


def source_identity(root=ROOT):
    """Hash actual tracked bytes and modes, never traverse dependency stores."""
    entries = output(["git", "ls-files", "-s", "-z"], root).split("\0")
    records = []
    for entry in entries:
        if not entry:
            continue
        metadata, name = entry.split("\t", 1)
        if excluded_source(name):
            continue
        path = root / name
        if path.is_symlink():
            content = digest(os.readlink(path))
        else:
            content = file_digest(path)
        records.append((name, metadata.split()[0], bool(path.lstat().st_mode & 0o111), content))
    return digest(records)


def require_clean(root=ROOT):
    # Retained evidence and plan documents cannot change tested code. Other
    # documentation, including guides, inventories and ADR policy, stays strict.
    changed = output(["git", "diff", "HEAD", "--name-only"], root).splitlines()
    untracked = output(["git", "ls-files", "--others", "--exclude-standard"], root).splitlines()
    invalid = [p for p in changed + untracked if not excluded_source(p)]
    if invalid:
        raise RuntimeError("Commit the candidate before the release gate: " + ", ".join(invalid[:12]))


def version(root=ROOT):
    versions = set()
    for package in PACKAGES:
        text = (root / package / (package + ".cabal")).read_text()
        match = re.search(r"^version:\s*([0-9]+(?:\.[0-9]+){3})\s*$", text, re.M | re.I)
        if not match:
            raise RuntimeError(f"No PVP version in {package}")
        versions.add(match[1])
    if len(versions) != 1:
        raise RuntimeError("The eight package versions differ")
    return versions.pop()


def corpus_clean(root=ROOT):
    status = output(["git", "status", "--porcelain", "--", "keiro-dsl/test"], root)
    if status:
        raise RuntimeError("Commit or stash corpus edits before regeneration (checked before compiling):\n" + status)


def published_blueprint(owner, relative):
    if output(["git", "status", "--porcelain", "--", relative], owner):
        raise RuntimeError(f"Entailed blueprint has unpublished working-tree edits: {relative}")
    run(["git", "fetch", "-q", "origin"], owner)
    head = output(["git", "ls-remote", "origin", "HEAD"], owner).split()
    if not head or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head[0]):
        raise RuntimeError("Cannot resolve the upstream default branch for the entailed blueprint")
    local = output(["git", "rev-parse", "HEAD:" + relative], owner)
    published = output(["git", "rev-parse", head[0] + ":" + relative], owner)
    if local != published:
        raise RuntimeError(f"Entailed blueprint differs from the published default branch: {relative}; sync/push its owner first")


def blueprint_preflight(root=ROOT):
    current = version(root)
    tags = output(["git", "tag", "--list", "keiro-*"], root).splitlines()
    key = lambda v: tuple(map(int, v.split(".")))
    previous = [t[6:] for t in tags if re.fullmatch(r"keiro-\d+(?:\.\d+){3}", t) and key(t[6:]) < key(current)]
    run(["seihou", "validate-blueprint", "blueprints/keiro-upgrade"], root)
    if not previous:
        return
    previous = max(previous, key=key)
    blueprint = json.loads(output(["dhall-to-json", "--file", "blueprints/keiro-upgrade/blueprint.dhall"], root))
    selected = [m for m in blueprint["migrations"] if key(previous) <= key(m["from"]) and key(m["to"]) <= key(current)]
    # Seihou reads installed artifacts, not our checkout. Preview from a disposable
    # project-local module directory; never replace the user's installed copies.
    owners = {"kiroku-upgrade": "mori://shinzui/kiroku"}
    with tempfile.TemporaryDirectory(prefix="keiro-blueprint-preflight-") as scratch:
        preview = Path(scratch)
        modules = preview / ".seihou/modules"
        modules.mkdir(parents=True)
        shutil.copytree(root / "blueprints/keiro-upgrade", modules / "keiro-upgrade")
        for edge in (e for migration in selected for e in migration.get("entails", [])):
            name = edge["blueprint"]
            if name not in owners:
                raise RuntimeError(f"Add the canonical Mori owner of entailed blueprint {name} to preflight")
            owner = Path(output(["mori", "path", owners[name]], root))
            relative = "blueprints/" + name
            published_blueprint(owner, relative)
            target = modules / name
            if not target.exists():
                shutil.copytree(owner / relative, target)
        run(["seihou", "agent", "--debug", "migrate", "keiro-upgrade", "--from", previous, "--to", current], preview)


def preflight(root=ROOT):
    if not os.environ.get("IN_NIX_SHELL"):
        raise RuntimeError("Run release commands inside nix develop")
    version(root)
    # Registry availability and cheap generated/document policies come FIRST.
    run(["z3", "--version"], root)
    run(["just", "release-static"], root)
    run(["just", "postgres-start"], root)
    blueprint_preflight(root)
    for package in PACKAGES:
        run(["cabal", "check"], root / package)
    run(["cabal", "build", "all", "--enable-tests", "--enable-benchmarks", "--dry-run"], root)
    plan = json.loads((root / "dist-newstyle/cache/plan.json").read_text())
    dependencies = published_dependencies(plan)
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(check_publication, package) for package in sorted(dependencies)]
        try:
            for future in as_completed(futures):
                future.result()
        except BaseException:
            for future in futures:
                future.cancel()
            raise
    print(f"HACKAGE_DEPENDENCIES: {len(dependencies)} released default library/executable dependencies", flush=True)
    run(["scripts/check-conformance-corpus.sh"], root)
    return plan


def published_dependencies(plan):
    """Walk default library/executable closure, excluding tests/manual-off pins."""
    units = {p["id"]: p for p in plan["install-plan"]}
    pending = [p["id"] for p in units.values() if p["pkg-name"] in PACKAGES and
               (p.get("component-name") == "lib" or p.get("component-name", "").startswith("exe:"))]
    seen, dependencies = set(), set()
    while pending:
        unit_id = pending.pop()
        if unit_id in seen:
            continue
        seen.add(unit_id)
        package = units[unit_id]
        pending.extend(package.get("depends", []) + package.get("exe-depends", []))
        if package["pkg-name"] in PACKAGES or package["type"] == "pre-existing":
            continue
        source = package.get("pkg-src", {})
        if source.get("type") != "repo-tar" or source.get("repo", {}).get("uri") not in (
                "http://hackage.haskell.org/", "https://hackage.haskell.org/"):
            raise RuntimeError(f"Default consumer dependency is not a Hackage release: {package['pkg-name']}")
        dependencies.add((package["pkg-name"], package["pkg-version"]))
    if not seen:
        raise RuntimeError("No published package roots found in the Cabal plan")
    return dependencies


def check_publication(package):
    name, selected = package
    request = urllib.request.Request(f"https://hackage.haskell.org/package/{name}.json",
                                     headers={"Accept": "application/json", "User-Agent": "keiro-release-preflight"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                versions = json.load(response)
        except (OSError, http.client.HTTPException, json.JSONDecodeError) as error:
            if isinstance(error, urllib.error.HTTPError) and 400 <= error.code < 500 and error.code != 429:
                raise RuntimeError(f"Hackage metadata unavailable for {name}: HTTP {error.code}") from error
            if attempt == 2:
                raise RuntimeError(f"Hackage metadata unavailable for {name} after 3 attempts: {type(error).__name__}") from error
            print(f"RETRY(metadata {name})={attempt + 1}/3: {type(error).__name__}", flush=True)
            time.sleep(2 ** attempt)
            continue
        if not isinstance(versions, dict) or versions.get(selected) != "normal":
            raise RuntimeError(f"Dependency is missing, deprecated or unpreferred on Hackage: {name}-{selected}")
        return


def identity(root=ROOT, plan=None):
    if plan is None:
        plan = json.loads((root / "dist-newstyle/cache/plan.json").read_text())
    # Cabal can change installed/configured status as it builds the same plan.
    packages = [{k: v for k, v in p.items() if k not in ("type", "dist-dir", "bin-file")} for p in plan["install-plan"]]
    # Nix assigns a new scratch directory/log descriptor on every shell entry;
    # neither changes the compiler, flags or runtime environment under test.
    relevant_env = {k: digest(v) for k, v in os.environ.items() if
                    k not in ("NIX_BUILD_TOP", "NIX_LOG_FD") and
                    (k.startswith(("PG", "GHC", "CABAL", "NIX", "KEIRO", "LC_", "LD_", "DYLD_", "PKG_CONFIG", "TASTY", "CCACHE_")) or
                     k in ("PATH", "LANG", "LANGUAGE", "TZ", "IN_NIX_SHELL", "DATABASE_URL",
                           "CC", "CXX", "CPP", "AR", "AS", "LD", "NM", "RANLIB", "CFLAGS", "CXXFLAGS",
                           "CPPFLAGS", "LDFLAGS", "CPATH", "LIBRARY_PATH"))}
    config = Path(output(["cabal", "path", "--config-file"], root))
    local_config = {}
    for path in (config, root / "cabal.project.local", root / "cabal.project.freeze"):
        local_config[str(path)] = file_digest(path) if path.exists() else None
    db = output(["psql", "-X", "-h", os.environ.get("PGHOST", str(root / "db")), "-d", "postgres", "-Atc",
                 "SELECT version(), pg_postmaster_start_time(), "
                 "(SELECT json_agg(json_build_array(name, setting, unit) ORDER BY name) FROM pg_settings)"], root)
    value = {
        "schema": SCHEMA, "source": source_identity(root),
        "dependencies": digest(sorted(packages, key=lambda p: p["id"])),
        "compiler": output(["ghc", "--info"], root),
        "cabal": output(["cabal", "--numeric-version"], root),
        "z3": output(["z3", "--version"], root),
        "postgres": digest(db), "machine": (platform.node(), platform.platform()),
        "environment": relevant_env, "local_config": local_config,
    }
    return value


def reusable(receipt, expected, root, now=None):
    now = time.time() if now is None else now
    try:
        log = root / receipt["log"]
        return (receipt["schema"] == SCHEMA and receipt["identity"] == expected
                and receipt["status"] == 0 and 0 <= now - receipt["finished"] <= MAX_AGE
                and file_digest(log) == receipt["log_sha256"])
    except (KeyError, OSError, TypeError):
        return False


class Gate:
    def __init__(self, root, inputs, fresh=False):
        self.root, self.inputs, self.fresh = root, inputs, fresh
        self.directory = root / EVIDENCE
        self.directory.mkdir(parents=True, exist_ok=True)
        self.run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        self.manifest = {"schema": SCHEMA, "commit": output(["git", "rev-parse", "HEAD"], root),
                         "inputs": inputs, "identity": digest(inputs), "started": time.time(), "stages": {}}
        self.path = self.directory / (self.run_id + "-manifest.json")
        atomic_json(self.path, self.manifest)

    def stage(self, name, command):
        expected = digest({"inputs": self.inputs, "command": command})
        attempts = []
        for path in self.directory.glob("*-" + name + ".json"):
            try:
                receipt = json.loads(path.read_text())
                if receipt.get("identity") == expected:
                    attempts.append((receipt["started"], path, receipt))
            except (ValueError, KeyError):
                continue
        if attempts and not self.fresh:
            _, path, receipt = max(attempts, key=lambda a: a[0])
            if reusable(receipt, expected, self.root):
                print(f"REUSED({name})={path.relative_to(self.root)}", flush=True)
                self.record(name, path, receipt, reused=True)
                return 0
        path = self.directory / (self.run_id + "-" + name + ".json")
        log = path.with_suffix(".log")
        receipt = {"schema": SCHEMA, "identity": expected, "command": command,
                   "started": time.time(), "load_average": os.getloadavg(),
                   "status": None, "log": str(log.relative_to(self.root))}
        atomic_json(path, receipt)  # An interrupted attempt supersedes an older pass.
        print(f"RUNNING({name})={log.relative_to(self.root)}", flush=True)
        with log.open("w") as stream:
            stream.write(json.dumps({"identity": expected, "command": command}) + "\n")
            stream.flush()
            process = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
            try:
                for line in process.stdout:
                    stream.write(line)
                    stream.flush()
                    print(line, end="", flush=True)
                status = process.wait()
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                process.stdout.close()
            if source_identity(self.root) != self.inputs["source"]:
                stream.write("SOURCE_CHANGED_DURING_STAGE\n")
                status = 1
            stream.write(f"STAGE_EXIT={status}\n")
        receipt.update(status=status, finished=time.time(), log_sha256=file_digest(log))
        atomic_json(path, receipt)
        self.record(name, path, receipt, reused=False)
        return status

    def record(self, name, path, receipt, reused):
        self.manifest["stages"][name] = {"receipt": str(path.relative_to(self.root)), "reused": reused,
                                          "status": receipt["status"], "sha256": file_digest(path)}
        atomic_json(self.path, self.manifest)

    def execute(self):
        if self.stage("correctness", ["just", "_verify"]):
            self.finish(False)
            return 1
        statuses = [self.stage(guard, ["scripts/bench-regression.sh", guard]) for guard in GUARDS]
        # Source edits during the gate cannot authorize the original candidate.
        unchanged = source_identity(self.root) == self.inputs["source"]
        self.finish(not any(statuses) and unchanged)
        return 0 if self.manifest["accepted"] else 1

    def finish(self, accepted):
        self.manifest.update(accepted=accepted, finished=time.time())
        atomic_json(self.path, self.manifest)
        print(f"RELEASE_GATE={'PASSED' if accepted else 'FAILED'} manifest={self.path.relative_to(self.root)}", flush=True)


def prepare(root=ROOT):
    version(root)
    corpus_clean(root)
    run(["nix", "fmt"], root)
    run(["cabal", "run", "-v0", "keiro-dsl-corpus-regen", "--", "regenerate"], root)
    run(["python3", "scripts/generate-record-migration-manifests.py"], root)
    print("Prepared final-version corpus and inventories. Review their diff, then commit before release-gate.")


def artifacts(root=ROOT):
    require_clean(root)
    source = source_identity(root)
    current = version(root)
    target = root / "dist-release" / current
    target.mkdir(parents=True, exist_ok=True)
    # One Cabal plan for every release package avoids per-package flag churn.
    # The shared workspace lock serializes it with verification. No uploads here.
    run(["cabal", "sdist", *PACKAGES, "--output-directory=" + str(target)], root)
    run(["cabal", "haddock", "--haddock-for-hackage", "--haddock-hyperlink-source", "--haddock-quickjump", *PACKAGES], root)
    for package in PACKAGES:
        shutil.copy2(root / "dist-newstyle" / f"{package}-{current}-docs.tar.gz", target)
    hashes = {p.name: file_digest(p) for p in sorted(target.glob("*.tar.gz"))}
    expected = {f"{p}-{current}{suffix}.tar.gz" for p in PACKAGES for suffix in ("", "-docs")}
    if set(hashes) != expected:
        raise RuntimeError("Expected exactly eight source and eight documentation archives")
    if source_identity(root) != source:
        raise RuntimeError("Candidate changed while building archives; rerun release-artifacts")
    atomic_json(target / "artifacts.json", {"version": current, "source": source, "sha256": hashes})
    print(f"Prepared sixteen archives and checksums in {target.relative_to(root)}")


def check_manifest(path, inputs, root=ROOT):
    manifest = json.loads(path.read_text())
    if (manifest.get("schema") != SCHEMA or not manifest.get("accepted")
            or manifest.get("identity") != digest(inputs)):
        raise RuntimeError("Release manifest is not accepted for the current inputs")
    if set(manifest["stages"]) != {"correctness", *GUARDS}:
        raise RuntimeError("Release manifest does not contain all seven stages")
    for stage, reference in manifest["stages"].items():
        if reference.get("status") != 0:
            raise RuntimeError(f"Manifest stage is not successful: {stage}")
        receipt_path = root / reference["receipt"]
        if file_digest(receipt_path) != reference["sha256"]:
            raise RuntimeError(f"Receipt checksum changed: {stage}")
        receipt = json.loads(receipt_path.read_text())
        command = ["just", "_verify"] if stage == "correctness" else ["scripts/bench-regression.sh", stage]
        expected = digest({"inputs": inputs, "command": command})
        if not reusable(receipt, expected, root):
            raise RuntimeError(f"Receipt is missing, stale or incompatible: {stage}")
        # A later red/interrupted run cannot be hidden by selecting an old manifest.
        for newer_path in (root / EVIDENCE).glob("*-" + stage + ".json"):
            newer = json.loads(newer_path.read_text())
            if newer.get("identity") == expected and newer["started"] > receipt["started"]:
                if not reusable(newer, expected, root):
                    raise RuntimeError(f"A later {stage} attempt failed or was interrupted")
    return manifest


def check_artifacts(root=ROOT):
    current = version(root)
    directory = root / "dist-release" / current
    inventory = json.loads((directory / "artifacts.json").read_text())
    if inventory["source"] != source_identity(root) or inventory["version"] != current:
        raise RuntimeError("Archives do not match the current candidate")
    expected = {f"{p}-{current}{suffix}.tar.gz" for p in PACKAGES for suffix in ("", "-docs")}
    if set(inventory["sha256"]) != expected:
        raise RuntimeError("Archive inventory does not include all sixteen archives")
    for name, checksum in inventory["sha256"].items():
        if file_digest(directory / name) != checksum:
            raise RuntimeError("Archive checksum changed: " + name)
    work = directory / "consumer-staged"
    result = json.loads((work / "result.json").read_text())
    if (result.get("status") != "passed" or result.get("source") != inventory["source"]
            or result.get("version") != current or not 0 <= time.time() - result["finished"] <= MAX_AGE):
        raise RuntimeError("Staged consumer has no current successful result")
    expected_archives = {n: h for n, h in inventory["sha256"].items() if not n.endswith("-docs.tar.gz")}
    if result["archives"] != expected_archives:
        raise RuntimeError("Staged consumer tested different source archives")
    if (file_digest(work / "proof.log") != result["log_sha256"] or
            file_digest(work / "dist-newstyle/cache/plan.json") != result["plan_sha256"]):
        raise RuntimeError("Staged consumer evidence changed")
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "preflight", "gate", "artifacts", "ready", "locked"))
    parser.add_argument("--fresh", action="store_true", help="Do not reuse stage receipts")
    args, remaining = parser.parse_known_args()
    if args.command not in ("locked", "ready") and remaining:
        parser.error("unrecognized arguments: " + " ".join(remaining))
    os.chdir(ROOT)
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    if not os.environ.get("IN_NIX_SHELL"):
        parser.error("Use nix develop -c just release-…")
    with workspace_lock():
        if args.command == "prepare":
            prepare()
        elif args.command == "preflight":
            preflight()
        elif args.command == "artifacts":
            artifacts()
        elif args.command == "ready":
            if len(remaining) != 1:
                parser.error("ready requires the accepted manifest path")
            require_clean()
            plan = preflight()
            check_manifest(Path(remaining[0]), identity(plan=plan))
            check_artifacts()
            print("RELEASE_READY: accepted gate, sixteen matching archives and staged consumer")
        elif args.command == "locked":
            command = remaining[1:] if remaining[:1] == ["--"] else remaining
            if not command:
                parser.error("locked requires a command after --")
            run(command)
        else:
            require_clean()
            plan = preflight()
            raise SystemExit(Gate(ROOT, identity(plan=plan), args.fresh).execute())


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"release: {error}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("release: interrupted; unfinished stages cannot be reused", file=sys.stderr)
        raise SystemExit(130)
