"""Alternate pre-change and candidate writer profiles on fresh durable fixtures.

Run inside nix develop after compiling the shared Haskell driver against both
package sets. The capacity directory must contain five pre-change saturation
legs. Each candidate mode gets a fresh process/server so server age and the
autovacuum startup clock do not systematically differ by mode.
"""

import argparse
import hashlib
import json
import math
import os
import re
from pathlib import Path
import statistics
import subprocess


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def has_headroom(result, offered):
    waits = [sample[0] for sample in result["samples_wait_schedule_claim_resume_us"]]
    block = max(1, len(waits) // 10)
    growth = statistics.fmean(waits[-block:]) - statistics.fmean(waits[:block])
    return result["throughput"] >= offered * 0.99 and growth <= 20000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("capacity", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--reuse-qualified", type=Path, help="reuse a previous five-baseline headroom-qualified rate")
    parser.add_argument(
        "--candidate-modes", nargs="+",
        choices=["idle", "active-1", "active-32", "active-32x1", "active-1x256", "active-32x256"],
        default=["idle", "active-1", "active-32"],
        help="candidate modes in addition to the unmounted control",
    )
    parser.add_argument(
        "--paired-controls", action="store_true",
        help="give every candidate mode an adjacent fresh baseline, reversing pair order on alternate trials",
    )
    parser.add_argument("--capabilities", type=int, default=2, help="matched GHC capabilities for every baseline and candidate leg")
    parser.add_argument("--nursery", help="matched RTS allocation area, for example 16m; default keeps the RTS default")
    args = parser.parse_args()
    if os.environ.get("KEIRO_INSPECTION_RETENTION_SECONDS") is not None:
        parser.error("run the streaming retention driver separately; this controller measures 20-second latency legs")
    if not 1 <= args.capabilities <= 128:
        parser.error("capabilities must be 1..128")
    if args.nursery and not re.fullmatch(r"[1-9][0-9]*[kKmMgG]", args.nursery):
        parser.error("nursery must be a positive size with k, m or g units")
    rts = [f"-N{args.capabilities}", *([f"-A{args.nursery}"] if args.nursery else []), "-T"]
    capacity_manifest = args.capacity / "manifest.json"
    if capacity_manifest.exists():
        capacity_settings = read(capacity_manifest).get("rts")
    else:
        capacity_settings = None
    if (capacity_settings or ["-N2", "-T"]) != rts:
        raise RuntimeError("capacity qualification does not match the requested RTS settings")
    driver_sha = digest(Path("scripts/inspection-http-interference-evidence.hs"))
    if not capacity_manifest.exists() or read(capacity_manifest).get("driver_sha256") != driver_sha:
        raise RuntimeError("capacity qualification must use the same retained driver source")
    if read(capacity_manifest).get("binary_sha256") != digest(args.baseline):
        raise RuntimeError("capacity qualification must use the identical baseline binary")
    if len(set(args.candidate_modes)) != len(args.candidate_modes):
        parser.error("candidate modes must be distinct")
    capacities = [read(path) for path in sorted(args.capacity.glob("*-unmounted.json"))]
    if len(capacities) != 5 or any(row["offered_ops_per_second"] is not None for row in capacities):
        raise RuntimeError("expected five unpaced pre-change capacity legs")
    offered = math.floor(min(row["throughput"] for row in capacities) * 0.75 / 10) * 10
    if not 1 <= offered <= 1000:
        raise RuntimeError(f"qualified rate outside driver range: {offered}")
    args.output.mkdir(parents=True, exist_ok=True)
    proposed = offered
    qualifications = []
    if args.reuse_qualified:
        prior = read(args.reuse_qualified / "manifest.json")
        previous_rate = prior["offered_writer_operations_per_second"]
        if prior.get("driver_sha256") != driver_sha or prior.get("baseline_binary_sha256") != digest(args.baseline):
            raise RuntimeError("previous qualification uses a different driver source or baseline binary")
        if prior.get("rts", ["-N2", "-T"]) != rts:
            raise RuntimeError("previous qualification uses different RTS settings")
        if prior["baseline_commit"] != "3bf3ac229f21d6c95179ce49b5e8f6323322f99b" or not 0 < previous_rate <= offered:
            raise RuntimeError("previous qualification does not match this baseline/rate proposal")
        for trial in range(1, 6):
            result = read(args.reuse_qualified / f"{trial}-baseline-unmounted/1-unmounted.json")
            if result["offered_ops_per_second"] != previous_rate or not has_headroom(result, previous_rate):
                raise RuntimeError("previous baseline does not establish headroom")
        offered = previous_rate
        qualifications.append({"offered": offered, "reused_from": str(args.reuse_qualified), "previous_baselines_checked": 5})
    while not qualifications or not args.reuse_qualified:
        directory = args.output / "paced-qualification" / str(offered)
        directory.parent.mkdir(parents=True, exist_ok=True)
        command = [str(args.baseline), str(directory), str(offered), "1", "unmounted", "+RTS", *rts, "-RTS"]
        with (directory.parent / f"{offered}.log").open("w") as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        result = read(directory / "1-unmounted.json")
        passed = has_headroom(result, offered)
        qualifications.append({"offered": offered, "passed": passed, "command": command})
        (args.output / "paced-qualification.json").write_text(json.dumps(qualifications, indent=2) + "\n")
        print(f"paced qualification {offered}/s throughput={result['throughput']:.1f} headroom={passed}", flush=True)
        if passed:
            break
        offered = math.floor(offered * 0.8 / 10) * 10
        if offered < 10:
            raise RuntimeError("unable to qualify even a low offered writer load")
    manifest = {
        "baseline_commit": "3bf3ac229f21d6c95179ce49b5e8f6323322f99b",
        "offered_writer_operations_per_second": offered,
        "selection_rule": "75% of minimum of five pre-change saturation throughputs rounded down to nearest ten, then fixed 20% reductions until paced headroom check passes",
        "initial_proposal": proposed,
        "paced_qualifications": qualifications,
        "baseline_binary_sha256": digest(args.baseline),
        "candidate_binary_sha256": digest(args.candidate),
        "driver_sha256": driver_sha,
        "client_sha256": digest(Path("scripts/inspection-http-poll-client.py")),
        "runner_sha256": digest(Path(__file__)),
        "rts": rts,
        "duration_seconds": 20,
        "fixture_workflow_rows": 100000,
        "repetitions": 5,
        "candidate_modes": args.candidate_modes,
        "control_protocol": "adjacent per-mode baseline/candidate pairs; pair order alternates by trial" if args.paired_controls else "one baseline for every candidate mode in each trial",
        "allocation_scope": "whole server process including inspection work; diagnostic only, not core-path allocation attribution; HTTP clients are external Python processes",
        "active_client_warmup": "one successful header per view on a retained TCP connection, then parent-controlled measurement start",
        "settle_seconds_after_warmup": 1,
        "checkpoint_before_writer_warmup": True,
        "headroom_check": "baseline throughput at least 99% of offered rate and last/first tenth mean queue delay growth at most 20ms",
        "order": [],
        "limitations": "workflow point headers only; not the full domain, large-value, slow-reader or retention matrix",
    }
    manifest_path = args.output / "manifest.json"
    for trial in range(1, 6):
        others = args.candidate_modes
        offset = (trial - 1) % len(others)
        modes = ["unmounted", *others[offset:], *others[:offset]]
        if args.paired_controls:
            legs = []
            for paired_mode in modes:
                pair = [("baseline", "unmounted", args.baseline, paired_mode), ("candidate", paired_mode, args.candidate, paired_mode)]
                legs.extend(pair if trial % 2 else reversed(pair))
        else:
            legs = [("baseline", "unmounted", args.baseline, None)]
            legs.extend(("candidate", mode, args.candidate, None) for mode in modes)
        for role, mode, executable, paired_mode in legs:
            label = f"baseline-for-{paired_mode}" if role == "baseline" and paired_mode else f"{role}-{mode}"
            directory = args.output / f"{trial}-{label}"
            command = [str(executable), str(directory), str(offered), "1", mode, "+RTS", *rts, "-RTS"]
            manifest["order"].append({"trial": trial, "role": role, "mode": mode, "paired_mode": paired_mode, "command": command})
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            with (args.output / f"{trial}-{label}.log").open("w") as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
            result = read(directory / f"1-{mode}.json")
            if role == "baseline" and not has_headroom(result, offered):
                raise RuntimeError(f"baseline lacks measured headroom at {offered}/s; retain rejected leg and qualify a lower fixed load")
            if result["poll_failure"]:
                raise RuntimeError(f"failed inspection requests in {directory}")
            expected_polls = {"active-1": 20, "active-32": 640, "active-32x1": 640, "active-1x256": 5120, "active-32x256": 5120}.get(mode, 0)
            if result["poll_success"] != expected_polls:
                raise RuntimeError(f"missing inspection requests in {directory}")
            print(f"trial={trial} {role} {mode} throughput={result['throughput']:.1f} p95_us={result['p95_us']:.0f} allocated={result['allocated_bytes']}", flush=True)

    comparisons = {}
    for mode in ["unmounted", *args.candidate_modes]:
        ratios = {"throughput": [], "p95_us": [], "allocated_bytes": []}
        for trial in range(1, 6):
            baseline_label = f"baseline-for-{mode}" if args.paired_controls else "baseline-unmounted"
            baseline = read(args.output / f"{trial}-{baseline_label}/1-unmounted.json")
            candidate = read(args.output / f"{trial}-candidate-{mode}/1-{mode}.json")
            for metric in ratios:
                ratios[metric].append(candidate[metric] / baseline[metric] - 1)
        comparisons[mode] = {metric: {"paired_changes": values, "median_change": statistics.median(values)} for metric, values in ratios.items()}
    (args.output / "comparisons.json").write_text(json.dumps(comparisons, indent=2) + "\n")
    print(json.dumps(comparisons, indent=2), flush=True)


if __name__ == "__main__":
    main()
