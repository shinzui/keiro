#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
folder="$PWD/keiro/bench/results/baseline-recording-v2"
unset KEIRO_BENCH_SETUP_TRACE KEIRO_BENCH_PRODUCER_PROBE KEIRO_BENCH_MAINTENANCE_PROBE KEIRO_BENCH_WORK_COUNTS KEIRO_BENCH_REBUILD_PROBE KEIRO_BENCH_COMMAND_PROBE KEIRO_BENCH_RESET_PROBE KEIRO_BENCH_INBOX_PLAN_PROBE KEIRO_BENCH_READ_MODEL_PLAN_PROBE KEIRO_INBOX_DELEGATED_EXPLAIN KEIRO_READ_MODEL_EXPLAIN KEIRO_READ_MODEL_P95 KEIRO_GUARDED_CATALOG_EVIDENCE
for run in subset full-1 full-2 full-3; do
  log="$folder/control-$run.txt"
  if [ -e "$log" ]; then echo "Refusing to overwrite $log" >&2; exit 2; fi
  {
    date -u +%FT%TZ
    git rev-parse HEAD
    shasum -a 256 "$(cabal list-bin keiro:bench:keiro-bench)" keiro/bench/baseline-*.csv
    uptime
  } > "$log"
  set +e
  if [ "$run" = subset ]; then
    just bench-regression command inbox >> "$log" 2>&1
  else
    just bench-regression >> "$log" 2>&1
  fi
  status=$?
  set -e
  printf 'PROCESS_EXIT=%s\n' "$status" >> "$log"
  printf 'CONTROL_FINISHED run=%s status=%s time=%s\n' "$run" "$status" "$(date -u +%FT%TZ)"
  if [ "$status" -ne 0 ]; then exit "$status"; fi
done
