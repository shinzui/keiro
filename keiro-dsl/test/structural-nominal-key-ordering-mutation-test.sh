#!/usr/bin/env bash
# Falsification evidence for consumer-bound identifier key ordering. Exit zero
# only when reversing the consumer Ord instance compiles and turns the named
# conformance assertion red.
set -euo pipefail

TARGET="keiro-dsl/test/conformance-structural-nominals/Conformance/StructuralNominals/Domain.hs"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-key-ordering-mutation.XXXXXX")"
case "$BACKUP_DIR" in
  *keiro-key-ordering-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $BACKUP_DIR"; exit 1 ;;
esac
BACKUP="$BACKUP_DIR/Domain.hs"
LOG="$BACKUP_DIR/mutation.log"
cp "$TARGET" "$BACKUP"

restore() {
  cp "$BACKUP" "$TARGET"
  rm -f "$BACKUP" "$LOG"
  rmdir "$BACKUP_DIR"
}
trap restore EXIT

run_suite() {
  cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals --test-show-details=direct
}

echo "== baseline: consumer key ordering is green =="
run_suite >/dev/null

perl -0pi -e 's/compare \(ClaimId left\) \(ClaimId right\) = compare left right/compare (ClaimId left) (ClaimId right) = compare right left/' "$TARGET"
if cmp -s "$BACKUP" "$TARGET"; then
  echo "FAIL: consumer Ord mutation target was not found"
  exit 1
fi

set +e
run_suite >"$LOG" 2>&1
STATUS=$?
set -e
if [[ "$STATUS" -eq 0 ]]; then
  sed -n '1,240p' "$LOG"
  echo "FAIL: reversed consumer Ord stayed green"
  exit 1
fi
if ! grep -Fq "FAIL  structural/nominal key ordering: ClaimId" "$LOG"; then
  sed -n '1,240p' "$LOG"
  echo "FAIL: reversed consumer Ord missed its named assertion"
  exit 1
fi
echo "ok: reversed consumer Ord turned its named assertion red"

cp "$BACKUP" "$TARGET"
echo "== restored baseline: consumer key ordering is green =="
run_suite >/dev/null
cmp -s "$BACKUP" "$TARGET"
echo "PASS: consumer key ordering mutation was caught and exact bytes restored"
