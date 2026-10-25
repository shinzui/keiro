#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
output="$PWD/keiro/bench/results/harness-isolation-v1"
unset KEIRO_BENCH_MAINTENANCE_PROBE KEIRO_BENCH_WORK_COUNTS KEIRO_BENCH_REBUILD_PROBE KEIRO_BENCH_COMMAND_PROBE KEIRO_BENCH_RESET_PROBE KEIRO_BENCH_INBOX_PLAN_PROBE KEIRO_BENCH_READ_MODEL_PLAN_PROBE KEIRO_INBOX_DELEGATED_EXPLAIN KEIRO_READ_MODEL_EXPLAIN KEIRO_READ_MODEL_P95 KEIRO_GUARDED_CATALOG_EVIDENCE
if [ -e "$output/paired-environment.txt" ]; then
  echo "Refusing to overwrite paired-environment.txt" >&2
  exit 2
fi
{
  date -u +%FT%TZ
  git rev-parse HEAD
  git diff --stat
  uname -a
  sysctl -n machdep.cpu.brand_string hw.memsize hw.logicalcpu
  ghc --version
  cabal --version
  postgres --version
  uptime
} > "$output/paired-environment.txt"
bench_binary="$(cabal list-bin keiro:bench:keiro-bench)"
for pair in 1 2 3; do
  if [ "$pair" -eq 2 ]; then selections=(full filtered); else selections=(filtered full); fi
  for selection in "${selections[@]}"; do
    if [ -e "$output/pair-$pair-$selection.csv" ]; then
      echo "Refusing to overwrite pair-$pair-$selection.csv" >&2
      exit 2
    fi
    pattern=()
    if [ "$selection" = filtered ]; then pattern=(-p command); fi
    KEIRO_BENCH_SETUP_TRACE=1 "$bench_binary" "${pattern[@]}" -j1 --time-mode wall --hide-progress --timeout 10s --stdev 5 --csv "$output/pair-$pair-$selection.csv" +RTS -N2 -RTS > "$output/pair-$pair-$selection.log" 2> "$output/pair-$pair-$selection.setup.log"
    status=$?
    printf "PAIR_RUN_FINISHED pair=%s selection=%s status=%s time=%s\n" "$pair" "$selection" "$status" "$(date -u +%FT%TZ)"
    printf 'PROCESS_EXIT=%s\n' "$status" >> "$output/pair-$pair-$selection.log"
  done
done
