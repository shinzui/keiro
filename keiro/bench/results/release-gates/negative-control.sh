#!/usr/bin/env bash
# Deliberately impossible baseline; restore the accepted CSV on every exit.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
git diff --quiet
git diff --cached --quiet
folder="$PWD/keiro/bench/results/release-gates"
target=keiro/bench/baseline-command.csv
for artifact in negative-control.txt negative-control.patch negative-control-source.txt; do
  if [ -e "$folder/$artifact" ]; then echo "Refusing to overwrite $artifact" >&2; exit 2; fi
done
backup="$(mktemp -t keiro-release-command-baseline.XXXXXX)"
cp "$target" "$backup"
restore_baseline() {
  cp "$backup" "$target"
}
trap restore_baseline EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{
  date -u +%FT%TZ
  git rev-parse HEAD
  shasum -a 256 "$target" "$(cabal list-bin keiro:bench:keiro-bench)" flake.lock
  z3 --version
  uptime
} > "$folder/negative-control-source.txt"
python3 - <<'PY'
import csv
from pathlib import Path
path = Path('keiro/bench/baseline-command.csv')
rows = list(csv.reader(path.open()))
assert rows[1][0] == 'All.command.legacy.accepted-1'
rows[1][1:] = ['1', '0']
with path.open('w', newline='') as handle:
    csv.writer(handle, lineterminator='\n').writerows(rows)
PY
git diff -- "$target" > "$folder/negative-control.patch"
set +e
just release-gate > "$folder/negative-control.txt" 2>&1
status=$?
set -e
printf 'PROCESS_EXIT=%s\n' "$status" >> "$folder/negative-control.txt"
restore_baseline
git diff --exit-code -- "$target"
if [ "$status" -ne 1 ]; then echo "Expected release-gate exit 1, got $status" >&2; exit 1; fi
python3 - <<'PY'
from pathlib import Path
lines = Path('keiro/bench/results/release-gates/negative-control.txt').read_text().splitlines()
assert 'VERIFY_EXIT=0' in lines and 'BENCH_EXIT=1' in lines
guards = [line for line in lines if line.startswith('GUARD(')]
assert guards == [f'GUARD({name})={int(name == "command")}' for name in
                  ['producer-identity', 'outbox', 'inbox', 'command', 'projection', 'read-model']], guards
assert 'BENCH_REGRESSION=FAILED' in lines and lines[-1] == 'PROCESS_EXIT=1'
print('NEGATIVE_CONTROL=PASSED; accepted baseline restored')
PY
