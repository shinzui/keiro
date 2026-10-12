#!/usr/bin/env python3
"""Summarize retained guarded-catalog evidence without discarding raw samples."""

import argparse
import gzip
import json
from pathlib import Path


def read_json(path):
    if path.suffix == ".gz":
        with gzip.open(path, "rt") as source:
            return json.load(source)
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    reports = {path.name: read_json(path) for path in sorted(args.directory.glob("*-report.json"))}
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
    summary = {"reports": reports, "failedReports": failed, "countChecks": counts, "storage": storage, "storageInterpretation": "Review continuing active backlog, expected committed-event growth, dead rows, vacuum and per-minute latency against the paired control. These metrics do not establish a universal storage bound."}
    destination = args.directory / "aggregate-report.json"
    destination.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"reports": len(reports), "failures": failed, "sustainedRuns": len(storage), "output": str(destination)}))


if __name__ == "__main__":
    main()
