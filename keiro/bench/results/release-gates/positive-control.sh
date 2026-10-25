#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
git diff --quiet
git diff --cached --quiet
folder="$PWD/keiro/bench/results/release-gates"
if [ -e "$folder/green-control.txt" ]; then echo 'Refusing to overwrite green release evidence' >&2; exit 2; fi
{
  date -u +%FT%TZ
  git rev-parse HEAD
  shasum -a 256 "$(cabal list-bin keiro:bench:keiro-bench)" flake.lock keiro/bench/baseline-*.csv
  z3 --version
  uptime
} > "$folder/green-source.txt"
set +e
just release-gate > "$folder/green-control.txt" 2>&1
status=$?
set -e
printf 'PROCESS_EXIT=%s\n' "$status" >> "$folder/green-control.txt"
if [ "$status" -ne 0 ]; then exit "$status"; fi
python3 - <<'PY'
from pathlib import Path
lines = Path('keiro/bench/results/release-gates/green-control.txt').read_text().splitlines()
assert 'VERIFY_EXIT=0' in lines and 'BENCH_EXIT=0' in lines
assert [line for line in lines if line.startswith('GUARD(')] == [
    f'GUARD({name})=0' for name in ['producer-identity', 'outbox', 'inbox', 'command', 'projection', 'read-model']]
assert 'BENCH_REGRESSION=PASSED' in lines and lines[-1] == 'PROCESS_EXIT=0'
print('FULL_RELEASE_GATE=PASSED')
PY
