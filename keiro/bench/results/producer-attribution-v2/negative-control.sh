#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
: "${IN_NIX_SHELL:?Run this script inside nix develop}"
git diff --quiet
git diff --cached --quiet
folder="$PWD/keiro/bench/results/producer-attribution-v2"
target=keiro/bench/ProducerIdentityBench.hs
if [ -e "$folder/negative-control.txt" ]; then echo 'Refusing to overwrite negative control' >&2; exit 2; fi
backup="$(mktemp -t keiro-producer-negative-control)"
cp "$target" "$backup"
restore_source() {
  cp "$backup" "$target"
}
trap restore_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - <<'PY'
from pathlib import Path
path = Path('keiro/bench/ProducerIdentityBench.hs')
text = path.read_text()
assert text.count('  result <- Store.runStoreIO store $ do') == 1
text = text.replace('import BenchSetup', 'import Control.Concurrent (threadDelay)\nimport BenchSetup', 1)
text = text.replace('  result <- Store.runStoreIO store $ do', '  when deterministic (threadDelay 20000)\n  result <- Store.runStoreIO store $ do', 1)
path.write_text(text)
PY
git diff -- "$target" > "$folder/negative-control.patch"
cabal build keiro:bench:keiro-bench > "$folder/negative-build.txt" 2>&1
{
  date -u +%FT%TZ
  git rev-parse HEAD
  shasum -a 256 "$(cabal list-bin keiro:bench:keiro-bench)" flake.lock
  uptime
} > "$folder/negative-environment.txt"
set +e
just bench-regression producer-identity > "$folder/negative-control.txt" 2>&1
status=$?
set -e
printf 'PROCESS_EXIT=%s\n' "$status" >> "$folder/negative-control.txt"
restore_source
trap - EXIT
git diff --exit-code -- "$target"
cabal build keiro:bench:keiro-bench > "$folder/restored-build.txt" 2>&1
if [ "$status" -ne 1 ]; then echo "Expected guard exit 1, got $status" >&2; exit 1; fi
python3 - <<'PY'
import json
from pathlib import Path
text = Path('keiro/bench/results/producer-attribution-v2/negative-control.txt').read_text()
ratios = []
for line in text.splitlines():
    if '"phase":"producer-fresh-ratio"' in line:
        ratios.append(json.loads(line[line.index('{'):]))
assert len(ratios) == 2 and {r['batch'] for r in ratios} == {False, True}
assert all(r['median_ratio'] > r['ceiling'] == 1.10 for r in ratios), ratios
assert 'GUARD(producer-identity)=1' in text and 'BENCH_REGRESSION=FAILED' in text
print('PRODUCER_NEGATIVE_CONTROL=PASSED; source restored and rebuilt')
PY
