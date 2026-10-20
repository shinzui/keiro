"""Repeat pooled/direct timer-lifetime attribution, outside domain acceptance."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path("keiro/bench/results/inspection/pool-timer-long-attribution")
binary = Path("/tmp/keiro-pool-retention-evidence")
manifest = {
    "candidate_commit": "5f5cafcc",
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "driver_sha256": hashlib.sha256((root / "driver.hs").read_bytes()).hexdigest(),
    "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    "ghc": "9.12.4",
    "library_optimization": "O1",
    "driver_optimization": "O2",
    "rts": ["-N2", "-T"],
    "hasql_pool_version": "1.4.2.3",
    "default_acquisition_timeout_seconds": 10,
    "duration_seconds": 180,
    "drain_seconds": 12,
    "queries_per_second": 200,
    "sample_interval_seconds": 5,
    "cohort_acceptance": False,
    "order": [],
}
for index, mode in enumerate(["direct", "pooled"], 1):
    name = f"{index}-{mode}"
    command = [
        str(binary), str(root / f"{name}.jsonl"), mode, "180", "200",
        "+RTS", "-N2", "-T", "-RTS",
    ]
    manifest["order"].append({"mode": mode, "command": command})
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (root / f"{name}.log").open("w") as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    print(f"completed {name}", flush=True)
