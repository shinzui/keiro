#!/usr/bin/env bash
# Mutation test for the Time/Natural replay-safety boundary (plan 157).
set -euo pipefail

HOLES="keiro-dsl/test/conformance-aggregate-scalars/AggregateScalars/ScalarLedger/Holes.hs"
BACKUP="$(mktemp)"
cp "$HOLES" "$BACKUP"
restore() {
  cp "$BACKUP" "$HOLES"
  rm -f "$BACKUP"
}
trap restore EXIT

echo "== baseline: scalar conformance is green =="
if cabal test keiro-dsl-conformance-aggregate-scalars >/dev/null 2>&1; then
  echo "ok: baseline green"
else
  echo "FAIL: baseline scalar conformance is not green"
  exit 1
fi

echo "== mutate: replace the emitted Natural with an idempotent dishonest value =="
sed -i.sed-bak \
  '/import Keiki.Builder qualified as B/a\
import Keiki.Core qualified as K
' \
  "$HOLES"
rm -f "$HOLES.sed-bak"
sed -i.sed-bak \
  's/^    , revision = d.revision$/    , revision = K.lit 1/' \
  "$HOLES"
rm -f "$HOLES.sed-bak"

echo "== rebuild + run conformance (expect the revision replay-safety gate red) =="
if MUTATION_OUTPUT="$(cabal test keiro-dsl-conformance-aggregate-scalars --test-show-details=direct 2>&1)"; then
  echo "$MUTATION_OUTPUT"
  echo "FAIL: the dishonest Natural event value was not caught"
  exit 1
fi
echo "$MUTATION_OUTPUT"

if ! printf '%s\n' "$MUTATION_OUTPUT" | grep -Fq 'is not replay-safe'; then
  echo "FAIL: expected replay-safety validation to reject the dishonest Natural"
  exit 1
fi
if ! printf '%s\n' "$MUTATION_OUTPUT" | grep -Fq 'revision'; then
  echo "FAIL: replay-safety failure did not identify the Natural register"
  exit 1
fi

echo "PASS: scalar replay-safety validation caught dishonest Natural persistence"
