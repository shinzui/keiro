#!/usr/bin/env python3
"""Compare fixed workloads with their immutable source on the current machine."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = "b8695a0d050c5b0db2f251887d43182da2b47eed"
CEILING = 1.25
MAX_AGE = 86400
CONFIRM_SECONDS = 240
GROUPS = ("outbox", "inbox", "command", "projection", "read-model")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def output(command, cwd=ROOT):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def run(command, cwd, log, timeout=600):
    print("+ " + " ".join(map(str, command)), flush=True)
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


@dataclass(frozen=True)
class Estimate:
    mean: float
    spread: float


def estimates(path, allow_empty=False):
    result = {}
    with Path(path).open() as stream:
        for row in csv.DictReader(stream):
            name = row["Name"]
            value = Estimate(float(row["Mean (ps)"]), float(row["2*Stdev (ps)"]))
            if name in result or not (math.isfinite(value.mean) and value.mean > 0
                                      and math.isfinite(value.spread) and value.spread >= 0):
                raise ValueError("Invalid or duplicate measurement: " + name)
            result[name] = value
    if not result and not allow_empty:
        raise ValueError("No measurements in " + str(path))
    return result


def compare(candidate, reference):
    lower = max(0, candidate.mean - candidate.spread) / (reference.mean + reference.spread)
    upper = ((candidate.mean + candidate.spread) / (reference.mean - reference.spread)
             if reference.mean > reference.spread else math.inf)
    # Preserve the existing mean-ratio budget. Uncertainty distinguishes an
    # over-budget result from a demonstrated regression; it does not invent a
    # tighter budget for measurements already within the limit.
    ratio = candidate.mean / reference.mean
    status = ("inconclusive" if reference.spread >= reference.mean or candidate.spread >= candidate.mean
              else "passed" if ratio <= CEILING else "regression" if lower > CEILING else "inconclusive")
    return {"status": status, "ratio": ratio,
            "lower": lower, "upper": upper if math.isfinite(upper) else None}


def confirmation_status(pairs):
    # Every observation counts. An uncertain or disagreeing confirmation blocks.
    states = [p["status"] for p in pairs]
    if len(states) != 2:
        return "inconclusive"
    if all(s == "passed" for s in states):
        return "passed"
    if all(s == "regression" for s in states):
        return "regression"
    return "inconclusive"


def valid_cache(metadata, key, paths, now=None):
    try:
        return (metadata["key"] == key
                and 0 <= (time.time() if now is None else now) - metadata["finished"] <= MAX_AGE
                and all(sha(path) == metadata["sha256"][path.name] for path in paths))
    except (KeyError, OSError, TypeError):
        return False


def environment():
    config = Path(output(["cabal", "path", "--config-file"]))
    return {"compiler": output(["ghc", "--info"]), "cabal": output(["cabal", "--numeric-version"]),
            "postgres": output(["postgres", "--version"]),
            "machine": [platform.node(), platform.platform(), os.cpu_count()],
            "flake": sha(ROOT / "flake.lock"), "config": sha(config),
            "environment": {k: digest(v) for k, v in os.environ.items()
                            if k not in ("NIX_BUILD_TOP", "NIX_LOG_FD", "KEIRO_BENCH_OUTPUT_DIRECTORY",
                                         "KEIRO_BENCH_LOCKED", "KEIRO_BENCH_FRESH_REFERENCE")
                            and (k.startswith(("PG", "GHC", "CABAL", "KEIRO", "LD_", "DYLD_", "LC_"))
                                 or k in ("PATH", "LANG", "TZ", "IN_NIX_SHELL"))}}


def reference_binary(context):
    build_context = {k: v for k, v in context.items() if k not in ("machine", "postgres", "environment")}
    build_context["environment"] = {k: v for k, v in context["environment"].items()
                                    if not k.startswith(("PG", "KEIRO"))}
    key = digest({"source": REFERENCE, "build_environment": build_context})
    cache = ROOT / "dist-newstyle/benchmark-reference" / key
    cache.parent.mkdir(parents=True, exist_ok=True)
    with (cache.parent / (key + ".lock")).open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        metadata_path = cache / "reference.json"
        if metadata_path.exists():
            metadata = json.loads(metadata_path.read_text())
            binary = cache / metadata["binary"]
            plan = cache / "dist-newstyle/cache/plan.json"
            if (metadata["key"] == key and metadata["source"] == REFERENCE
                    and sha(binary) == metadata["binary_sha256"] and sha(plan) == metadata["plan_sha256"]):
                return cache, binary, metadata
            raise ValueError("Reference cache integrity failed; refusing to use it")
        # An unfinished owned build is never a usable reference.
        if cache.exists():
            shutil.rmtree(cache)
        cache.mkdir()
        if subprocess.run(["git", "cat-file", "-e", REFERENCE + "^{commit}"], cwd=ROOT,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            if run(["git", "fetch", "origin", REFERENCE], ROOT, cache / "fetch.log"):
                raise ValueError("Cannot obtain the pinned benchmark reference")
        archive = subprocess.Popen(["git", "archive", REFERENCE], cwd=ROOT, stdout=subprocess.PIPE)
        try:
            subprocess.run(["tar", "-x", "-C", str(cache)], stdin=archive.stdout, check=True)
        finally:
            archive.stdout.close()
        if archive.wait():
            raise ValueError("Cannot extract immutable benchmark reference")
        if run(["cabal", "build", "keiro:bench:keiro-bench"], cache, cache / "build.log"):
            raise ValueError("Reference build failed; see " + str(cache / "build.log"))
        binary = Path(output(["cabal", "list-bin", "keiro:bench:keiro-bench"], cache))
        plan = cache / "dist-newstyle/cache/plan.json"
        metadata = {"key": key, "source": REFERENCE, "binary": str(binary.relative_to(cache)),
                    "binary_sha256": sha(binary), "plan_sha256": sha(plan), "build_environment": build_context}
        save(metadata_path, metadata)
        return cache, binary, metadata


def measure(binary, cwd, pattern, target, stem, timeout=600, historical=None, allow_timeouts=False,
            timeout_inventory=None, recoverable_names=None):
    csv_path = target / (stem + ".csv")
    command = [str(binary), "-p", pattern, "-j1", "--time-mode", "wall", "--hide-progress",
               "--stdev", "5", "--timeout", "10s", "--csv", str(csv_path)]
    if historical is not None:
        command += ["--baseline", str(historical)]  # Diagnostics, not cross-environment acceptance.
    command += ["+RTS", "-N2", "-RTS"]
    record = {"command": command, "cwd": str(cwd), "started": time.time(), "load_average": os.getloadavg()}
    command_path = target / (stem + "-command.json")
    save(command_path, record)
    status = run(command, cwd, target / (stem + ".log"), timeout)
    transcript = (target / (stem + ".log")).read_text()
    failures = re.search(r"(\d+) out of (\d+) tests failed", transcript)
    timeout_only = (status == 1 and failures is not None
                    and int(failures[1]) == transcript.count("Timed out after ")
                    and not re.search(r"\bFAIL\b|Exception", transcript))
    values = estimates(csv_path, allow_empty=True) if csv_path.exists() else {}
    recoverable = (allow_timeouts and timeout_only and timeout_inventory is not None
                   and int(failures[2]) == len(timeout_inventory)
                   and len(values) + int(failures[1]) == len(timeout_inventory)
                   and values.keys() <= timeout_inventory
                   and timeout_inventory - values.keys() <= (
                       recoverable_names if recoverable_names is not None else timeout_inventory))
    record.update(status=status, timeout_only=timeout_only, recoverable=recoverable, finished=time.time())
    save(command_path, record)
    if status and not recoverable:
        raise RuntimeError("Benchmark assertion/execution failed: " + stem)
    # A timeout is an incomplete observation, never a pass. Every missing case
    # must complete both targeted confirmations before the family can pass.
    if not values and not recoverable:
        raise ValueError("No measurements in " + str(csv_path))
    return values


def confirmation_pattern(name, names):
    # Preserve the existing within-run comparisons when filtering a domain/versioned case.
    selected = {name}
    if ".domain." in name:
        legacy = name.replace(".domain.", ".legacy.")
        if legacy.endswith(".rejected"):
            legacy = legacy.removesuffix(".rejected") + ".no-op"
        selected.add(legacy)
        if name.endswith(".accepted-1"):
            selected.add(name.replace(".domain.", ".control."))
    if ".versioned." in name:
        selected.add(name.replace(".versioned.", ".legacy."))
    return " || ".join("$0 == " + json.dumps(n) for n in sorted(selected & names))


def guard(group, target):
    target.mkdir(parents=True, exist_ok=True)
    save(target / "result.json", {"schema": 1, "group": group, "status": "running", "started": time.time()})
    context = environment()
    baseline = ROOT / "keiro/bench" / ("baseline-" + group + ".csv")
    historical = estimates(baseline)
    if run(["cabal", "build", "keiro:bench:keiro-bench"], ROOT, target / "build.log"):
        raise RuntimeError("Candidate benchmark build failed")
    candidate = Path(output(["cabal", "list-bin", "keiro:bench:keiro-bench"]))
    candidate_sha256 = sha(candidate)
    cache, reference, metadata = reference_binary(context)
    save(target / "reference.json", metadata)
    shutil.copyfile(cache / "dist-newstyle/cache/plan.json", target / "reference-plan.json")
    shutil.copyfile(cache / "build.log", target / "reference-build.log")
    # Reference timings are reusable only under the same environment, for at most 24h.
    key = digest({"reference": metadata, "candidate_sha256": candidate_sha256, "measurement_environment": context,
                  "group": group, "historical_sha256": sha(baseline)})
    samples = cache / ("samples-" + key)
    samples.mkdir(exist_ok=True)
    paths = [samples / "reference.csv", samples / "reference.log", samples / "reference-command.json"]
    state = samples / "sample.json"
    previous = json.loads(state.read_text()) if state.exists() else {}
    reused = os.environ.get("KEIRO_BENCH_FRESH_REFERENCE") != "1" and valid_cache(previous, key, paths)
    if not reused:
        try:
            measure(reference, cache / "keiro", group, samples, "reference", allow_timeouts=True,
                    timeout_inventory=set(historical))
            command = json.loads((samples / "reference-command.json").read_text())
            previous = {"key": key, "finished": time.time(), "load_average": os.getloadavg(),
                        "complete": command["status"] == 0,
                        "sha256": {p.name: sha(p) for p in paths}}
            # Incomplete references are retained but cannot enter the timing cache.
            if previous["complete"]:
                save(state, previous)
        finally:
            for path in paths:
                if path.exists():
                    shutil.copyfile(path, target / path.name)
    else:
        for path in paths:
            shutil.copyfile(path, target / path.name)
    save(target / "sample.json", previous)
    ref = estimates(target / "reference.csv", allow_empty=True)
    values = measure(candidate, ROOT / "keiro", group, target, "candidate", historical=baseline,
                     allow_timeouts=True, timeout_inventory=set(ref), recoverable_names=set(historical))
    cases = {}
    for name in sorted(historical):
        case = (compare(values[name], ref[name]) if name in values and name in ref
                else {"status": "inconclusive", "reason": "Initial measurement timed out"})
        if name in values:
            case["historical_ratio"] = values[name].mean / historical[name].mean
        cases[name] = case
    result = {"schema": 1, "group": group, "status": "running", "ceiling": CEILING,
              "reference_source": REFERENCE, "reference_reused": reused, "cases": cases,
              "candidate_sha256": candidate_sha256,
              "measurement_environment": context}
    save(target / "result.json", result)
    flagged = [name for name, case in cases.items() if case["status"] != "passed"]
    if flagged:
        # Four fixture lifecycles per family, regardless of the number of noisy
        # cases. Preserve every within-run comparison dependency in the filter.
        pattern = " || ".join(sorted({confirmation_pattern(name, set(historical)) for name in flagged}))
        deadline = time.monotonic() + CONFIRM_SECONDS
        pairs = []
        for pair, order in enumerate((("candidate", "reference"), ("reference", "candidate"))):
            observations = {}
            for role in order:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                binary, cwd = (candidate, ROOT / "keiro") if role == "candidate" else (reference, cache / "keiro")
                observations[role] = measure(binary, cwd, pattern, target,
                                             f"confirm-{pair}-{role}", timeout=remaining)
            if len(observations) != 2:
                break
            pairs.append({name: compare(observations["candidate"][name], observations["reference"][name])
                          for name in flagged})
        for name in flagged:
            confirmations = [pair[name] for pair in pairs]
            cases[name]["confirmation"] = confirmations
            cases[name]["status"] = confirmation_status(confirmations)
        save(target / "result.json", result)
    states = {case["status"] for case in cases.values()}
    if sha(candidate) != candidate_sha256 or sha(reference) != metadata["binary_sha256"]:
        raise ValueError("A benchmark executable changed during measurement")
    status = "regression" if "regression" in states else "inconclusive" if "inconclusive" in states else "passed"
    result.update(status=status, finished=time.time(), load_average=os.getloadavg())
    save(target / "result.json", result)
    print(f"PERFORMANCE({group})={status.upper()} cases={len(cases)} evidence={target}", flush=True)
    return 0 if status == "passed" else 1 if status == "regression" else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=GROUPS)
    args = parser.parse_args()
    if not os.environ.get("IN_NIX_SHELL"):
        parser.error("Run benchmark guards inside nix develop")
    target = Path(os.environ.get("KEIRO_BENCH_OUTPUT_DIRECTORY", str(
        ROOT / "keiro/bench/results/release-gates" / ("comparison-" + uuid.uuid4().hex))))
    try:
        if os.environ.get("KEIRO_BENCH_LOCKED") == "1":
            return guard(args.group, target)
        from release_workflow import workspace_lock
        with workspace_lock():
            return guard(args.group, target)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, RuntimeError) as error:
        target.mkdir(parents=True, exist_ok=True)
        status = "benchmark-error" if isinstance(error, RuntimeError) else "inconclusive"
        result_path = target / "result.json"
        result = json.loads(result_path.read_text()) if result_path.exists() else {"group": args.group}
        if any(c["status"] == "regression" for c in result.get("cases", {}).values()):
            status = "regression"
        result.update(status=status, error=str(error), finished=time.time())
        save(result_path, result)
        print(f"PERFORMANCE({args.group})={status.upper()}: {error}", flush=True)
        return 1 if status in ("benchmark-error", "regression") else 2


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda _s, _f: (_ for _ in ()).throw(KeyboardInterrupt()))
    raise SystemExit(main())
