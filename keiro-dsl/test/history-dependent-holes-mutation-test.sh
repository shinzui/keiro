#!/usr/bin/env bash
# BUG-10: each invalid witness must fail the initial-hole harness by name.
set -euo pipefail

WITNESSES=keiro-dsl/test/conformance-history-dependent-holes/HistoryDependentHoles/Assignment/BehaviorHoles.hs
HARNESS=keiro-dsl/test/conformance-history-dependent-holes/Generated/HistoryDependentHoles/Assignment/Harness.hs
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-initial-hole.XXXXXX")"
cp "$WITNESSES" "$BACKUP_DIR/BehaviorHoles.hs"
cleanup() {
  cp "$BACKUP_DIR/BehaviorHoles.hs" "$WITNESSES"
  rm -f "$BACKUP_DIR/BehaviorHoles.hs" "$BACKUP_DIR/mutation.log"
  rmdir "$BACKUP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_fixture() {
  cabal test -v0 keiro-dsl-conformance-history-dependent-holes --test-show-details=direct
}

run_fixture >"$BACKUP_DIR/mutation.log" 2>&1
grep -Fq 'case step assignmentTransducer (AssignmentActive, initialAssignmentRegs) (Touch' "$HARNESS"
echo 'ok: baseline and generated-owned Touch probe'

mutate() {
  python3 - "$BACKUP_DIR/BehaviorHoles.hs" "$WITNESSES" "$1" <<'PY'
from pathlib import Path
import sys
source, target, mutation = sys.argv[1:]
text = Path(source).read_text()
live = 'behavior-v1-fe7277b756f0ff4b'
replay = 'behavior-v1-afe574346545beaa'
set_key = 'behavior-v1-73b7455c36956c2b'
line = next(row for row in text.splitlines(keepends=True) if live in row)
if mutation == 'missing':
    text = text.replace(line, '')
elif mutation == 'duplicate':
    text = text.replace(line, line + line)
elif mutation == 'pending':
    text = text.replace(line, '  , Pending (BehaviorKey "' + live + '")\n')
elif mutation == 'stale':
    text = text.replace(live, live[:-1] + 'c')
elif mutation in ('replay sibling', 'wrong edge'):
    other = replay if mutation == 'replay sibling' else set_key
    text = text.replace(live, 'fe7277b756f0ff4b-KEY').replace(other, live).replace('fe7277b756f0ff4b-KEY', other)
elif mutation == 'inadequate history':
    text = text.replace(line, line.replace('[PropertySet (PropertySetData "colour" "blue")]', '[]'))
elif mutation == 'lying emissions':
    text = text.replace(line, line.replace('PropertyClearedData "colour"', 'PropertyClearedData "other"'))
else:
    raise ValueError(mutation)
assert text != Path(source).read_text(), mutation
Path(target).write_text(text)
PY
}

expect_red() {
  local mutation="$1" row="$2" diagnostic="${3:-}"
  mutate "$mutation"
  local status=0
  run_fixture >"$BACKUP_DIR/mutation.log" 2>&1 || status=$?
  if [[ "$status" == 0 ]] ||
     ! grep -Fq 'FAIL  accepts ClearProperty from AssignmentActive' "$BACKUP_DIR/mutation.log" ||
     ! grep -Fq "FAIL  forward/replay equality: ClearProperty from AssignmentActive -- hole witness $row" "$BACKUP_DIR/mutation.log" ||
     { [[ -n "$diagnostic" ]] && ! grep -Fq "$diagnostic" "$BACKUP_DIR/mutation.log"; }; then
    cat "$BACKUP_DIR/mutation.log"
    echo "FAIL: $mutation did not fail through the expected harness rows ($row, $diagnostic)"
    exit 1
  fi
  cp "$BACKUP_DIR/BehaviorHoles.hs" "$WITNESSES"
  echo "ok: $mutation -> hole witness $row ${diagnostic}"
}

expect_red missing filled
expect_red duplicate filled
expect_red pending filled
expect_red stale filled 'stale: 1'
expect_red 'replay sibling' verified '[witness-kind]'
expect_red 'inadequate history' verified '[unexpected-rejection]'
expect_red 'lying emissions' verified '[event-value-mismatch]'
expect_red 'wrong edge' verified '[command-mismatch]'
run_fixture >"$BACKUP_DIR/mutation.log" 2>&1
git diff --check
echo 'PASS: all eight initial-hole mutations failed by name; witnesses restored'
