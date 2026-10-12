#!/usr/bin/env python3
"""Execute Plan 306's unchanged matrix in an exclusively leased cell payload.

Entry arguments are payload root, sealed work file and cell output directory.
The owner protocol supplies CELL_ENV_FILE and bounds the whole process group.
"""

from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: guarded-catalog-cell <payload-root> <work-file> <output-dir>")
    payload, work_file, output = map(Path, sys.argv[1:])
    work = json.loads(work_file.read_text())
    candidate = json.loads((payload / "share/candidate-environment.json").read_text())
    baseline = json.loads((payload / "share/enhanced-environment.json").read_text())
    spec = importlib.util.spec_from_file_location("monitor", payload / "share/scripts/run-guarded-catalog-comparison.py")
    monitor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(monitor)
    if (work.get("schema") != "keiro.guarded-catalog-cell-work/v1"
            or work.get("candidateCommit") != candidate["candidateCommit"]
            or work.get("originalLibraryCommit") != baseline["originalLibraryCommit"]
            or candidate["originalLibraryCommit"] != baseline["originalLibraryCommit"]
            or candidate["compiler"] != baseline["compiler"]
            or sorted(candidate["dependencies"]) != sorted(baseline["dependencies"])):
        raise SystemExit("work/build identity mismatch")
    for name, expected in baseline["harnessFiles"].items():
        if monitor.digest(payload / "share" / name) != expected:
            raise SystemExit(f"shared harness digest mismatch: {name}")
    for path, expected in [(payload / "bin/keiro-bench", candidate["candidateSha256"]),
                           (payload / "bin/ordinary-baseline", baseline["sha256"])]:
        if monitor.digest(path) != expected:
            raise SystemExit(f"packaged executable digest mismatch: {path.name}")
    cell = json.loads(Path(os.environ["CELL_ENV_FILE"]).read_text())
    if (cell["schema"] != "cell.environment/v1" or not cell.get("leaseId")
            or cell.get("runId") != os.environ["CELL_RUN_ID"]):
        raise SystemExit("cell execution identity mismatch")
    matrix = output / "matrix"
    matrix.mkdir()
    retained = output / "baseline"
    retained.mkdir()
    baseline["retainedExecutable"] = str(payload / "bin/ordinary-baseline")
    (retained / "enhanced-environment.json").write_text(json.dumps(baseline, indent=2) + "\n")
    candidate.update(executionCell=cell["cell"], executionRun=cell["runId"],
                     leaseId=cell["leaseId"], isolation="cell lease; health evidence requires owner verification",
                     packagedExecutable=str(payload / "bin/keiro-bench"))
    (matrix / "candidate-environment.json").write_text(json.dumps(candidate, indent=2) + "\n")
    (matrix / "runtime-environment.json").write_bytes((payload / "share/runtime-environment.json").read_bytes())
    (output / "work.json").write_bytes(work_file.read_bytes())
    environment = dict(os.environ, KEIRO_GUARDED_CATALOG_EVIDENCE="compare",
                       KEIRO_GUARDED_CATALOG_PG_ADMIN=cell["postgres"]["connectionString"],
                       KEIRO_GUARDED_CATALOG_BASELINE=str(retained),
                       KEIRO_GUARDED_CATALOG_OUTPUT=str(matrix))
    contaminated = False
    exit_code = None
    process = None
    reader = None
    with (matrix / "host-activity.jsonl").open("w") as hosts, (matrix / "comparison.log").open("w") as log:
        try:
            for _ in range(6):
                snapshot = monitor.host_snapshot()
                hosts.write(json.dumps(snapshot) + "\n")
                hosts.flush()
                if snapshot["blockers"]:
                    raise RuntimeError("competing build/test detected before measurement")
                time.sleep(5)
            process = subprocess.Popen([str(payload / "bin/keiro-bench"), "+RTS", "-N2", "-RTS"],
                                       cwd=payload / "share/keiro", env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
            def copy_log():
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    sys.stdout.write(line)
                    sys.stdout.flush()
            reader = threading.Thread(target=copy_log)
            reader.start()
            while process.poll() is None:
                snapshot = monitor.host_snapshot()
                hosts.write(json.dumps(snapshot) + "\n")
                hosts.flush()
                if snapshot["blockers"]:
                    contaminated = True
                    os.killpg(process.pid, signal.SIGINT)
                    break
                time.sleep(5)
            try:
                exit_code = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                exit_code = process.wait(timeout=30)
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                process.wait(timeout=30)
            if reader is not None:
                reader.join(timeout=30)
            (matrix / "execution.json").write_text(json.dumps({"exitCode": exit_code,
                "contaminated": contaminated, "finishedAt": datetime.now(timezone.utc).isoformat()}, indent=2) + "\n")
    summary = subprocess.run([sys.executable, str(payload / "share/scripts/summarize-guarded-catalog-evidence.py"),
                              str(matrix), "--require-complete"])
    raise SystemExit(2 if contaminated else exit_code if exit_code else summary.returncode)


if __name__ == "__main__":
    main()
