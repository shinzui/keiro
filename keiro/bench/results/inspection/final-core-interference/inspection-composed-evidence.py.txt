"""Matched ordinary-writer measurements; inspection costs are diagnostics.

Run inside nix develop after compiling the same retained benchmark source with
and without KEIRO_INSPECTION_BASELINE against isolated package sets. Never link
the pre-change writer with the candidate runtime. Each leg owns a fresh durable
database and process. No quiet-machine lease is required.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--rate", type=int, default=100)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--modes", nargs="+", default=["disabled", "idle", "active-shared", "active-distinct", "slow-reader", "churn"])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    rts = ["-N8", "-A16m", "-T"]
    manifest = {
        "baseline_commit": "3bf3ac229f21d6c95179ce49b5e8f6323322f99b",
        "candidate_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "baseline_sha256": sha(args.baseline), "candidate_sha256": sha(args.candidate),
        "rts": rts, "rate": args.rate, "seconds": args.seconds, "rounds": args.rounds,
        "modes": args.modes,
        "source_sha256": {str(path): sha(path) for path in [Path("keiro-ops-http/bench/InspectionInterference.hs"), Path("keiro-ops-http/bench/InspectionClients.hs"), Path(__file__)]},
        "design": "Fresh-process/database block controls; alternate baseline-first/baseline-last each round, rotate candidate order. Same baseline block controls each mode; retain every sample.",
        "allocation_scope": "writer_thread_allocated_bytes_per_operation measures the calling runtime thread; process allocation and WAL are diagnostics, with external client allocation excluded",
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def run(name, binary, mode, rate):
        output = args.output / name
        env = {**os.environ, "KEIRO_INSPECTION_SECONDS": str(args.seconds)}
        with (args.output / f"{name}.log").open("w") as log:
            subprocess.run([str(binary), str(output), str(rate), "1", mode, "+RTS", *rts, "-RTS"], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        row = json.loads((output / f"1-{mode}.json").read_text())
        print(f"{name}: throughput={row['throughput']:.2f} p95_us={row['p95_us']} writer_bytes={row['writer_thread_allocated_bytes_per_operation']:.0f}", flush=True)
        return row

    capacity = [run(f"capacity-{n}", args.baseline, "disabled", "saturation") for n in range(1, 6)]
    if args.rate > min(row["throughput"] for row in capacity) * 0.75:
        raise RuntimeError("offered rate lacks baseline capacity headroom; lower --rate")
    blocks = []
    for trial in range(1, args.rounds + 1):
        modes = args.modes[trial % len(args.modes):] + args.modes[:trial % len(args.modes)]
        block = {"trial": trial, "candidate": {}}
        if trial % 2:
            block["baseline"] = run(f"{trial}-baseline", args.baseline, "disabled", args.rate)
        for mode in modes:
            block["candidate"][mode] = run(f"{trial}-{mode}", args.candidate, mode, args.rate)
        if not trial % 2:
            block["baseline"] = run(f"{trial}-baseline", args.baseline, "disabled", args.rate)
        waits = [sample[0] for sample in block["baseline"]["samples_wait_schedule_claim_resume_timer_us_writer_bytes"]]
        if block["baseline"]["throughput"] < args.rate * 0.99 or statistics.mean(waits[-len(waits)//10:]) - statistics.mean(waits[:len(waits)//10]) > 20000:
            raise RuntimeError("baseline fixed-load run did not establish headroom")
        blocks.append(block)

    summary = {}
    for mode in args.modes:
        metrics = {}
        for metric in ["throughput", "p95_us", "writer_thread_allocated_bytes_per_operation"]:
            ratios = [block["candidate"][mode][metric] / block["baseline"][metric] - 1 for block in blocks]
            metrics[metric] = {"median_change": statistics.median(ratios), "paired_changes": ratios}
        metrics["within_core_gate"] = metrics["throughput"]["median_change"] >= -0.05 and metrics["p95_us"]["median_change"] <= 0.05 and metrics["writer_thread_allocated_bytes_per_operation"]["median_change"] <= 0.05
        summary[mode] = metrics
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    for mode, row in summary.items():
        print(mode, {key: round(value["median_change"] * 100, 2) for key, value in row.items() if isinstance(value, dict)}, "within_gate=", row["within_core_gate"], flush=True)
    if not all(row["within_core_gate"] for row in summary.values()):
        raise SystemExit("Core-path acceptance is unresolved; investigate reproducible effects or extend noisy comparisons.")


if __name__ == "__main__":
    main()
