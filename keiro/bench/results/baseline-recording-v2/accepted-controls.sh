#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
git diff --quiet
git diff --cached --quiet
folder="$PWD/keiro/bench/results/baseline-recording-v2"
unset KEIRO_BENCH_SETUP_TRACE KEIRO_BENCH_PRODUCER_PROBE KEIRO_BENCH_MAINTENANCE_PROBE KEIRO_BENCH_WORK_COUNTS KEIRO_BENCH_REBUILD_PROBE KEIRO_BENCH_COMMAND_PROBE KEIRO_BENCH_RESET_PROBE KEIRO_BENCH_INBOX_PLAN_PROBE KEIRO_BENCH_READ_MODEL_PLAN_PROBE KEIRO_INBOX_DELEGATED_EXPLAIN KEIRO_READ_MODEL_EXPLAIN KEIRO_READ_MODEL_P95 KEIRO_GUARDED_CATALOG_EVIDENCE
for run in 1 2 3; do
  log="$folder/accepted-full-$run.txt"
  if [ -e "$log" ]; then echo "Refusing to overwrite $log" >&2; exit 2; fi
  {
    date -u +%FT%TZ
    git rev-parse HEAD
    shasum -a 256 "$(cabal list-bin keiro:bench:keiro-bench)" keiro/bench/baseline-*.csv
    uptime
  } > "$log"
  set +e
  just bench-regression >> "$log" 2>&1
  status=$?
  set -e
  printf 'PROCESS_EXIT=%s\n' "$status" >> "$log"
  printf 'CONTROL_FINISHED run=%s status=%s time=%s\n' "$run" "$status" "$(date -u +%FT%TZ)"
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  python3 - "$log" <<'PY'
import json
import statistics
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
lines = text.splitlines()
assert [line for line in lines if line.startswith('GUARD(')] == [
    f'GUARD({name})=0' for name in ['producer-identity', 'outbox', 'inbox', 'command', 'projection', 'read-model']]
assert lines[-1] == 'PROCESS_EXIT=0' and 'BENCH_REGRESSION=PASSED' in lines
ratios = [json.loads(line[line.index('{'):]) for line in lines if '"phase":"producer-fresh-ratio"' in line]
assert len(ratios) == 2 and {r['batch'] for r in ratios} == {False, True}
for row in ratios:
    pairs = row['pairs_ns_legacy_deterministic']
    assert len(pairs) == 15 and all(l > 0 and d > 0 for l, d in pairs)
    measured = statistics.median(d / l for l, d in pairs)
    assert abs(measured - row['median_ratio']) < 1e-9 and measured <= row['ceiling'] == 1.10
PY
done
