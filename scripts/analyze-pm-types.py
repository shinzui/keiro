"""Trial-level paired median ratios with a fixed-seed percentile bootstrap.

Ratios above one always mean worse. No operations are resampled independently.
An interval wholly above one rejects regression; an upper endpoint >=1.01 is
inconclusive. A median above one is an unresolved adverse trend. Same-source
controls must satisfy the resolution requirement too. Keep every raw sample.
"""
import json
import math
import random
import statistics
import sys
from pathlib import Path


def analyze(root, pairs):
    if pairs < 5:
        raise ValueError("at least five independent trial pairs required")
    comparisons = [
        ("disabled", "baseline-disabled", "candidate-disabled"),
        ("capacity", "baseline-capacity", "candidate-capacity"),
        ("idle", "baseline-idle", "candidate-idle"),
        ("same-source", "control-a", "control-b"),
        ("catalog-polling", "catalog-idle", "catalog-active"),
        ("many-polling", "many-idle", "many-active"),
        ("catalog-versus-prechange", "baseline-idle", "catalog-active"),
        ("many-versus-prechange", "baseline-idle", "many-active"),
    ]
    metrics = ["throughput", "p95_us", "p99_us", "writer_thread_allocated_bytes_per_operation"]
    rng = random.Random(323)
    data = {}
    for label in {name for _, left, right in comparisons for name in (left, right)}:
        data[label] = []
        for pair in range(1, pairs + 1):
            paths = list((root / label / str(pair)).glob("*.json"))
            if len(paths) != 1:
                raise ValueError(f"missing or ambiguous trial: {label}/{pair}")
            sample = json.loads(paths[0].read_text())
            raw = sample["samples_wait_schedule_claim_resume_timer_us_writer_bytes"]
            if not raw or any(not sample[m] or not math.isfinite(sample[m]) for m in metrics):
                raise ValueError(f"missing or nonfinite samples: {paths[0]}")
            if any(len(row) != 6 for row in raw) or not math.isclose(
                len(raw) / sample["elapsed_seconds"], sample["throughput"], rel_tol=1e-9
            ):
                raise ValueError(f"missing writer samples: {paths[0]}")
            rate = sample["offered_ops_per_second"]
            if rate and sample["throughput"] < rate * 0.99:
                raise ValueError(f"lost offered writer load: {paths[0]}")
            if label in ("catalog-active", "many-active"):
                seconds = len(raw) / rate
                if sample["poll_failure"] or sample["poll_success"] != 4 * seconds:
                    raise ValueError(f"rejected or lost polling load: {paths[0]}")
                resources = sample["resources_after_clients"]
                if resources != {"views": 0, "connections": 0, "wake_pump": False}:
                    raise ValueError(f"abandoned inspection resources: {paths[0]}")
            data[label].append(sample)
    results = []
    for name, left, right in comparisons:
        for metric in metrics:
            ratios = [b[metric] / a[metric] if metric != "throughput" else a[metric] / b[metric]
                      for a, b in zip(data[left], data[right])]
            boot = sorted(statistics.median(rng.choices(ratios, k=pairs)) for _ in range(20000))
            median = statistics.median(ratios)
            lo, hi = boot[499], boot[19499]
            status = "regression" if lo > 1 else "inconclusive" if hi >= 1.01 or median > 1 else "passed"
            if name == "same-source" and lo <= 1 / 1.01:
                status = "inconclusive"
            results.append(dict(comparison=name, metric=metric, ratios=ratios,
                                median=median, ci95=[lo, hi], status=status))
    report = dict(seed=323, resamples=20000, pairs=pairs, results=results,
                  status="passed" if all(r["status"] == "passed" for r in results) else "not-accepted")
    (root / "analysis.json").write_text(json.dumps(report, indent=2) + "\n")
    for result in results:
        print(f'{result["comparison"]} {result["metric"]}: {result["median"]:.6f} '
              f'CI95={result["ci95"]} {result["status"]}')
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(analyze(Path(sys.argv[1]), int(sys.argv[2])))
