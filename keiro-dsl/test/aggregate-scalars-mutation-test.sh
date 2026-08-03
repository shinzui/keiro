#!/usr/bin/env bash
# Mutation test for the Time/Natural forward-versus-replay assertion (plan 157).
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
  's/^    , revision = d.revision$/    , revision = B.lit 1/' \
  "$HOLES"
rm -f "$HOLES.sed-bak"

echo "== rebuild + run conformance (expect exactly the revision register red) =="
if MUTATION_OUTPUT="$(cabal test keiro-dsl-conformance-aggregate-scalars --test-show-details=direct 2>&1)"; then
  echo "$MUTATION_OUTPUT"
  echo "FAIL: the dishonest Natural event value was not caught"
  exit 1
fi
echo "$MUTATION_OUTPUT"

FAIL_LINES="$(printf '%s\n' "$MUTATION_OUTPUT" | grep '^FAIL  ' || true)"
EXPECTED_FAIL="PASS  forward/replay equality: Record from ScalarLedgerEmpty -- register revision"
if [[ "$FAIL_LINES" != "${EXPECTED_FAIL/PASS/FAIL}" ]]; then
  echo "FAIL: expected exactly the Natural register assertion to turn red"
  exit 1
fi

for EXPECTED_PASS in \
  "PASS  validateTransducer is empty" \
  "PASS  golden round-trip: ScalarsRecorded" \
  "PASS  accepts Record from ScalarLedgerEmpty" \
  "PASS  forward/replay equality: Record from ScalarLedgerEmpty -- final vertex" \
  "PASS  forward/replay equality: Record from ScalarLedgerEmpty -- register observedAt"; do
  if ! printf '%s\n' "$MUTATION_OUTPUT" | grep -Fq "$EXPECTED_PASS"; then
    echo "FAIL: expected still-green assertion missing: $EXPECTED_PASS"
    exit 1
  fi
done

echo "PASS: scalar forward/replay equality caught dishonest Natural persistence"
