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
from pathlib import Path
import statistics
import subprocess


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("capacity", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    capacities = [read(path) for path in sorted(args.capacity.glob("*-unmounted.json"))]
    if len(capacities) != 5 or any(row["offered_ops_per_second"] is not None for row in capacities):
        raise RuntimeError("expected five unpaced pre-change capacity legs")
    offered = math.floor(min(row["throughput"] for row in capacities) * 0.75 / 10) * 10
    if not 1 <= offered <= 1000:
        raise RuntimeError(f"qualified rate outside driver range: {offered}")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "baseline_commit": "3bf3ac229f21d6c95179ce49b5e8f6323322f99b",
        "offered_writer_operations_per_second": offered,
        "selection_rule": "75% of the minimum of five pre-change saturation throughputs, rounded down to nearest ten",
        "baseline_binary_sha256": digest(args.baseline),
        "candidate_binary_sha256": digest(args.candidate),
        "driver_sha256": digest(Path("scripts/inspection-http-interference-evidence.hs")),
        "client_sha256": digest(Path("scripts/inspection-http-poll-client.py")),
        "runner_sha256": digest(Path(__file__)),
        "rts": ["-N2", "-T"],
        "duration_seconds": 20,
        "fixture_workflow_rows": 100000,
        "repetitions": 5,
        "allocation_scope": "runtime process; HTTP clients are external Python processes",
        "headroom_check": "baseline throughput at least 99% of offered rate and last/first tenth mean queue delay growth at most 20ms",
        "order": [],
        "limitations": "workflow point headers only; not the full domain, large-value, slow-reader or retention matrix",
    }
    manifest_path = args.output / "manifest.json"
    for trial in range(1, 6):
        others = ["idle", "active-1", "active-32"]
        offset = (trial - 1) % len(others)
        modes = ["unmounted", *others[offset:], *others[:offset]]
        legs = [("baseline", "unmounted", args.baseline)]
        legs.extend(("candidate", mode, args.candidate) for mode in modes)
        for role, mode, executable in legs:
            directory = args.output / f"{trial}-{role}-{mode}"
            command = [str(executable), str(directory), str(offered), "1", mode, "+RTS", "-N2", "-T", "-RTS"]
            manifest["order"].append({"trial": trial, "role": role, "mode": mode, "command": command})
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            with (args.output / f"{trial}-{role}-{mode}.log").open("w") as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
            result = read(directory / f"1-{mode}.json")
            if role == "baseline":
                waits = [sample[0] for sample in result["samples_wait_schedule_claim_resume_us"]]
                block = max(1, len(waits) // 10)
                growth = statistics.fmean(waits[-block:]) - statistics.fmean(waits[:block])
                if result["throughput"] < offered * 0.99 or growth > 20000:
                    raise RuntimeError(f"baseline lacks measured headroom at {offered}/s; retain rejected leg and qualify a lower fixed load")
            if result["poll_failure"]:
                raise RuntimeError(f"failed inspection requests in {directory}")
            expected_polls = {"active-1": 20, "active-32": 640}.get(mode, 0)
            if result["poll_success"] != expected_polls:
                raise RuntimeError(f"missing inspection requests in {directory}")
            print(f"trial={trial} {role} {mode} throughput={result['throughput']:.1f} p95_us={result['p95_us']:.0f} allocated={result['allocated_bytes']}", flush=True)

    comparisons = {}
    for mode in ["unmounted", "idle", "active-1", "active-32"]:
        ratios = {"throughput": [], "p95_us": [], "allocated_bytes": []}
        for trial in range(1, 6):
            baseline = read(args.output / f"{trial}-baseline-unmounted/1-unmounted.json")
            candidate = read(args.output / f"{trial}-candidate-{mode}/1-{mode}.json")
            for metric in ratios:
                ratios[metric].append(candidate[metric] / baseline[metric] - 1)
        comparisons[mode] = {metric: {"paired_changes": values, "median_change": statistics.median(values)} for metric, values in ratios.items()}
    (args.output / "comparisons.json").write_text(json.dumps(comparisons, indent=2) + "\n")
    print(json.dumps(comparisons, indent=2), flush=True)


if __name__ == "__main__":
    main()
