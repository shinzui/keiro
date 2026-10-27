#!/usr/bin/env bash
# Compiled proof that a consumer nominal enum compared with a qualified literal
# yields a transducer that compiles under the generated-output -Werror and a
# harness that samples by canonical key rather than supplied fixture order.
# The nominal-scalars fixture and its hand-owned fixture order are mutated,
# the suite is regenerated and run, and every byte is restored afterwards.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FIXTURE="keiro-dsl/test/fixtures/nominal-scalars.keiro"
ROOT="keiro-dsl/test/conformance-nominal-scalars"
BINDINGS="$ROOT/NominalConformance/Bindings.hs"
HARNESS="$ROOT/Generated/NominalScalars/NominalLedger/Harness.hs"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-consumer-enum-literal.XXXXXX")"
case "$BACKUP_DIR" in
  *keiro-consumer-enum-literal.*) ;;
  *) echo "FAIL: unexpected backup path: $BACKUP_DIR"; exit 1 ;;
esac
cp "$FIXTURE" "$BACKUP_DIR/fixture.keiro"
cp -R "$ROOT" "$BACKUP_DIR/root"
LOG="$BACKUP_DIR/suite.log"

restore() {
  cp "$BACKUP_DIR/fixture.keiro" "$FIXTURE"
  cp -R "$BACKUP_DIR/root/." "$ROOT/"
  rm -rf "$BACKUP_DIR"
}
trap restore EXIT

python3 - "$FIXTURE" "$BINDINGS" <<'PY'
import sys
from pathlib import Path

fixture, bindings = Path(sys.argv[1]), Path(sys.argv[2])
source = fixture.read_text()
old = 'guard cmd.orderId == reg.orderId && cmd.status == reg.status'
if source.count(old) != 1:
    raise SystemExit('expected exactly one nominal-scalars guard')
fixture.write_text(source.replace(old, 'guard cmd.orderId == reg.orderId && cmd.status == OrderStatus.Draft'))
source = bindings.read_text()
old = '''        [ NominalFixture "draft" (String "draft") AwaitingApproval
        , NominalFixture "submitted" (String "submitted") Accepted
        ]'''
new = '''        [ NominalFixture "submitted" (String "submitted") Accepted
        , NominalFixture "draft" (String "draft") AwaitingApproval
        ]'''
if source.count(old) != 1:
    raise SystemExit('expected exactly one OrderStatus fixture list')
bindings.write_text(source.replace(old, new))
PY

cabal run -v0 keiro-dsl-corpus-regen -- regenerate --allow-dirty --only "$ROOT" >"$LOG" 2>&1 || {
  sed -n '1,120p' "$LOG"
  echo "FAIL: regeneration with a literal-guarded consumer enum failed"
  exit 1
}
if ! grep -Fq 'fieldWitnessGet NominalProjections.orderStatusEqualityWitness value == "draft"' "$HARNESS"; then
  echo "FAIL: generated harness does not sample the consumer enum by canonical key"
  exit 1
fi
if ! cabal test -v0 keiro-dsl:test:keiro-dsl-conformance-nominal-scalars --test-show-details=direct >"$LOG" 2>&1; then
  sed -n '1,200p' "$LOG"
  echo "FAIL: literal-guarded consumer enum suite failed with the non-matching fixture first"
  exit 1
fi
echo "PASS: consumer enum literal guard compiles and samples by canonical key"
