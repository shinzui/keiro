"""Single-run client-shape diagnostic. This is not a five-run acceptance gate."""
import hashlib
import json
from pathlib import Path
import subprocess

output = Path("keiro/bench/results/inspection/http-client-matrix-smoke")
baseline = Path("/tmp/keiro-http-client-matrix-prechange")
candidate = Path("/tmp/keiro-http-client-matrix-evidence")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


manifest = {
    "baseline_commit": "3bf3ac229f21d6c95179ce49b5e8f6323322f99b",
    "candidate_commit": "5f5cafcc",
    "baseline_binary_sha256": digest(baseline),
    "candidate_binary_sha256": digest(candidate),
    "driver_sha256": digest(output / "driver.hs"),
    "client_sha256": digest(output / "client.py"),
    "runner_sha256": digest(Path(__file__)),
    "common_dependency_unit_differences": [],
    "common_dependency_packages_checked": 284,
    "ghc": "9.12.4",
    "library_optimization": "O1",
    "driver_optimization": "O2",
    "rts": ["-N2", "-T"],
    "offered_writer_operations_per_second": 380,
    "rate_qualification": "matched-http-qualified (all five old-runtime baselines); reassess headroom per retained leg",
    "duration_seconds": 20,
    "fixture_workflow_rows": 100000,
    "trials": 1,
    "cohort_acceptance": False,
    "order": [],
}
results = {}
legs = [("baseline", "unmounted", baseline)]
legs += [
    ("candidate", mode, candidate)
    for mode in ["unmounted", "idle", "active-32x1", "active-1x256", "active-32x256"]
]
for role, mode, executable in legs:
    name = f"{role}-{mode}"
    directory = output / name
    command = [
        str(executable), str(directory), "380", "1", mode,
        "+RTS", "-N2", "-T", "-RTS",
    ]
    manifest["order"].append({"role": role, "mode": mode, "command": command})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (output / f"{name}.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = json.loads((directory / f"1-{mode}.json").read_text())
    waits = [sample[0] for sample in result["samples_wait_schedule_claim_resume_us"]]
    size = max(1, len(waits) // 10)
    growth = sum(waits[-size:]) / size - sum(waits[:size]) / size
    result["headroom_check"] = result["throughput"] >= 380 * 0.99 and growth <= 20000
    result["queue_growth_us"] = growth
    results[name] = result
    print(name, {key: result[key] for key in [
        "poll_success", "poll_failure", "allocated_bytes", "p95_us",
        "throughput", "headroom_check",
    ]}, flush=True)
base = results["baseline-unmounted"]
summary = {}
for name, result in results.items():
    summary[name] = {
        "poll_success": result["poll_success"],
        "poll_failure": result["poll_failure"],
        "headroom_check": result["headroom_check"],
        "queue_growth_us": result["queue_growth_us"],
        "changes_from_prechange": {
            metric: result[metric] / base[metric] - 1
            for metric in ["allocated_bytes", "cpu_ns", "p95_us", "throughput"]
        },
    }
(output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
