#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
output="$PWD/keiro/bench/results/harness-isolation-v1"
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
