#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
output="$PWD/keiro/bench/results/harness-isolation-v1"
unset KEIRO_BENCH_MAINTENANCE_PROBE KEIRO_BENCH_WORK_COUNTS KEIRO_BENCH_REBUILD_PROBE KEIRO_BENCH_COMMAND_PROBE KEIRO_BENCH_RESET_PROBE KEIRO_BENCH_INBOX_PLAN_PROBE KEIRO_BENCH_READ_MODEL_PLAN_PROBE KEIRO_INBOX_DELEGATED_EXPLAIN KEIRO_READ_MODEL_EXPLAIN KEIRO_READ_MODEL_P95 KEIRO_GUARDED_CATALOG_EVIDENCE
if [ -e "$output/command-growth-durable-blocks.txt" ]; then
  echo "Refusing to overwrite command-growth-durable-blocks.txt" >&2
  exit 2
fi
bench_binary="$(cabal list-bin keiro:bench:keiro-bench)"
{
  date -u +%FT%TZ
  git rev-parse HEAD
  git diff --stat
  shasum -a 256 "$bench_binary"
  uname -a
  sysctl -n machdep.cpu.brand_string hw.memsize hw.logicalcpu
  ghc --version
  cabal --version
  postgres --version
  uptime
} > "$output/growth-environment.txt"
KEIRO_BENCH_SETUP_TRACE=1 "$bench_binary" --list-tests > "$output/accepted-list-tests.txt" 2> "$output/accepted-list-tests.stderr"
set +e
KEIRO_BENCH_COMMAND_PROBE=1 "$bench_binary" +RTS -N2 -RTS > "$output/command-growth-durable-blocks.txt" 2> "$output/command-growth-durable-blocks.stderr"
status=$?
printf 'PROCESS_EXIT=%s\n' "$status" >> "$output/command-growth-durable-blocks.txt"
exit "$status"
