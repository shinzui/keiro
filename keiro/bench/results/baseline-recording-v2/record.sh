#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
git diff --quiet
git diff --cached --quiet
results="$PWD/keiro/bench/results"
unset KEIRO_BENCH_PRODUCER_PROBE KEIRO_BENCH_MAINTENANCE_PROBE KEIRO_BENCH_WORK_COUNTS KEIRO_BENCH_REBUILD_PROBE KEIRO_BENCH_COMMAND_PROBE KEIRO_BENCH_RESET_PROBE KEIRO_BENCH_INBOX_PLAN_PROBE KEIRO_BENCH_READ_MODEL_PLAN_PROBE KEIRO_INBOX_DELEGATED_EXPLAIN KEIRO_READ_MODEL_EXPLAIN KEIRO_READ_MODEL_P95 KEIRO_GUARDED_CATALOG_EVIDENCE
for group in command outbox inbox projection read-model; do
  folder="$results/$group-v2"
  if [ -e "$folder/environment.txt" ] || [ -e "$folder/sample-1.csv" ]; then
    echo "Refusing to overwrite $group-v2 recording evidence" >&2
    exit 2
  fi
  mkdir -p "$folder"
done
bench_binary="$(cabal list-bin keiro:bench:keiro-bench)"
{
  date -u +%FT%TZ
  git rev-parse HEAD
  shasum -a 256 "$bench_binary" flake.lock
  uname -a
  sysctl -n machdep.cpu.brand_string hw.memsize hw.logicalcpu
  ghc --version
  cabal --version
  postgres --version
  uptime
} > "$results/baseline-recording-v2/environment.txt"
for group in command outbox inbox projection read-model; do
  cp "$results/baseline-recording-v2/environment.txt" "$results/$group-v2/environment.txt"
done
for sample in 1 2 3 4 5; do
  for group in command outbox inbox projection read-model; do
    folder="$results/$group-v2"
    unset KEIRO_READ_MODEL_P95
    if [ "$group" = projection ]; then export KEIRO_READ_MODEL_P95=1; fi
    set +e
    KEIRO_BENCH_SETUP_TRACE=1 "$bench_binary" -p "$group" -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --csv "$folder/sample-$sample.csv" +RTS -N2 -RTS > "$folder/sample-$sample.txt" 2> "$folder/sample-$sample.stderr"
    status=$?
    set -e
    printf 'PROCESS_EXIT=%s\n' "$status" >> "$folder/sample-$sample.txt"
    printf 'RECORDING_FINISHED sample=%s group=%s status=%s time=%s\n' "$sample" "$group" "$status" "$(date -u +%FT%TZ)"
    if [ "$status" -ne 0 ]; then exit "$status"; fi
  done
done
