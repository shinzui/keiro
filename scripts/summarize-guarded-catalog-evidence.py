#!/usr/bin/env python3
"""Summarize retained guarded-catalog evidence without discarding raw samples."""

import argparse
import gzip
import json
import math
from pathlib import Path


def read_json(path):
    if path.suffix == ".gz":
        with gzip.open(path, "rt") as source:
            return json.load(source)
    return json.loads(path.read_text())


def ratio_summary(report):
    """Keep the Haskell harness's upper-median convention, plus the spread."""
    pairs = report.get("ratios", [])
    result = {}
    for index, name in enumerate(["throughput", "p95", "p99"]):
        values = sorted(pair[index] for pair in pairs)
        if values:
            result[name] = {"count": len(values), "median": values[len(values)//2],
                            "minimum": values[0], "maximum": values[-1]}
    return result


def matrix_inventory(directory, reports):
    """Explicitly account for every required comparison, including missing runs."""
    manifest_path = directory / "manifest.json"
    if not manifest_path.exists() or read_json(manifest_path).get("mode") != "compare":
        return {"applicable": False, "complete": False}
    expected = set()
    for size in [10000, 1000000]:
        for connections in [1, 8]:
            for batch in [1, 4]:
                for worker in [False, True]:
                    base = f"{size}-{connections}-{batch}-{worker}"
                    expected.add(f"refactor-{base}-0-0-True-Nothing-report.json")
                    for kind in ["empty", "miss"]:
                        expected.add(f"{kind}-{base}-100-0-True-Nothing-report.json")
                    for spread in [False, True]:
                        expected.add(f"hit-{base}-100-100-{spread}-Nothing-report.json")
                        for duplicates in [0, 50, 100]:
                            expected.add(f"mixed-{base}-20-{duplicates}-{spread}-Nothing-report.json")
    missing = sorted(expected - reports.keys())
    fixed_arrival = []
    for worker in [False, True]:
        capacity_path = directory / f"capacity-{worker}-rates.json"
        capacity = read_json(capacity_path)["fixedCapacity"] if capacity_path.exists() else None
        for fraction in [0.5, 0.8]:
            for duplicates in [0, 50, 100]:
                prefix = f"fixed-arrival-1000000-8-4-{worker}-20-{duplicates}-True-"
                matches = [name for name in reports if name.startswith(prefix) and capacity is not None
                           and math.isclose(float(name[len(prefix):-len("-report.json")]),
                                            capacity * fraction, rel_tol=1e-12)]
                if len(matches) == 1:
                    fixed_arrival.extend(matches)
                else:
                    missing.append(f"{prefix}<capacity * {fraction}>-report.json")
        sustained = f"sustained-{worker}-report.json"
        expected.add(sustained)
        if sustained not in reports:
            missing.append(sustained)
    present = (expected & reports.keys()) | set(fixed_arrival)
    missing_samples = []
    malformed_pairs = []
    for name in sorted(present):
        if name.startswith("sustained-"):
            stems = [name.removesuffix("-report.json") + "-" + label for label in ["control", "duplicates"]]
            stems += [stem + "-storage" for stem in stems]
            paths = [stem + (".jsonl" if stem.endswith("-storage") else ".json.gz") for stem in stems]
        else:
            if len(reports[name].get("ratios", [])) != 5:
                malformed_pairs.append(name)
            paths = [f"{name.removesuffix('-report.json')}-{pair}-{side}.json.gz"
                     for pair in range(1, 6) for side in ["control", "candidate"]]
        missing_samples.extend(path for path in paths if not (directory / path).exists())
    return {"applicable": True, "expectedReports": 190, "presentReports": len(present),
            "missingReports": sorted(missing), "missingSamples": missing_samples,
            "incompletePairSets": malformed_pairs,
            "complete": not (missing or missing_samples or malformed_pairs)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--require-complete", action="store_true",
                        help="exit nonzero unless the full comparison matrix and raw evidence exist and all budgets pass")
    args = parser.parse_args()
    reports = {path.name: read_json(path) for path in sorted(args.directory.glob("*-report.json")) if path.name != "aggregate-report.json"}
    counts = {}
    for path in sorted(args.directory.glob("*.json.gz")):
        measurement = read_json(path)
        workload = measurement["workload"]
        completed = len(measurement["samples"])
        accepted = sum(sample["accepted"] for sample in measurement["samples"])
        expected_events = (100 + accepted) * workload["batchSize"]
        valid = completed == workload["attempts"] and measurement["endingCardinality"] == workload["cardinality"] + accepted and measurement["committedEvents"] == expected_events
        counts[path.name] = {"valid": valid, "attempts": completed, "acceptedBatches": accepted, "refusedBatches": completed-accepted, "committedMeasuredEvents": measurement["committedEvents"] - 100 * workload["batchSize"], "endingCardinality": measurement["endingCardinality"]}
        if not valid:
            raise SystemExit(f"cardinality/event-count evidence mismatch: {path}")
    storage = {}
    for path in sorted(args.directory.glob("*-storage.jsonl")):
        snapshots = [json.loads(line) for line in path.read_text().splitlines()]
        raw = args.directory / (path.name.removesuffix("-storage.jsonl") + ".json.gz")
        measurement = read_json(raw)
        first, last = snapshots[0], snapshots[-1]
        wal_delta = float(last["wal"]["wal_bytes"]) - float(first["wal"]["wal_bytes"])
        table_data = {}
        before = {(row["schema"], row["table"]): row for row in first["tables"]}
        for row in last["tables"]:
            key = row["schema"], row["table"]
            original = before.get(key)
            table_data[".".join(key)] = {
                "final": row,
                "deltas": {name: row[name] - original[name] for name in ["bytes", "relationBytes", "indexBytes", "live", "dead", "autovacuumCount"]} if original else None,
            }
        minutes = []
        for n in range(10):
            values = sorted(sample["latencyMicros"] for sample in measurement["samples"] if sample["cohort"] == "ordinary" and n * 60 <= sample["completedSeconds"] < (n + 1) * 60)
            minutes.append({"minute": n + 1, "count": len(values), **({"p95": values[min(len(values)-1, int(len(values)*0.95))], "p99": values[min(len(values)-1, int(len(values)*0.99))]} if values else {})})
        storage[path.name] = {
            "walBytesPerCompletedAttempt": wal_delta / len(measurement["samples"]),
            "walScope": "direct pg_stat_wal cluster delta; includes normal background activity, not a per-database attribution",
            "databaseGrowthBytes": last["databaseBytes"] - first["databaseBytes"],
            "backlogSamples": [{"at": row["at"], "head": row["head"], "worker": row["worker"], "eventsBehind": row["head"] - row["worker"]} for row in snapshots],
            "tables": table_data,
            "ordinaryLatencyByMinute": minutes,
            "activeWorker": measurement["workload"]["activeWorker"],
            "completedAttempts": len(measurement["samples"]),
            "elapsedSeconds": measurement["elapsedSeconds"],
        }
    failed = [name for name, report in reports.items() if report.get("pass", report.get("latencyPass")) is False]
    matrix = matrix_inventory(args.directory, reports)
    status = "failed" if failed else "incomplete" if not matrix["complete"] else "storage-review-required"
    summary = {"reports": reports, "ratioSummaries": {name: ratio_summary(report) for name, report in reports.items() if "ratios" in report}, "failedReports": failed, "countChecks": counts, "matrix": matrix, "performanceAcceptance": status, "storage": storage, "storageInterpretation": "Review continuing active backlog, expected committed-event growth, dead rows, vacuum and per-minute latency against the paired control. These metrics do not establish a universal storage bound."}
    destination = args.directory / "aggregate-report.json"
    destination.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"reports": len(reports), "failures": failed, "sustainedRuns": len(storage), "performanceAcceptance": status, "output": str(destination)}))
    if args.require_complete and (not matrix["complete"] or failed):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
