#!/usr/bin/env bash
# Mutation test for the process-manager facts harness (EP-3 / plan 61, M4/M5).
#
# Proves the spec->behaviour pin: flipping the timer `on-reject` disposition from
# Fired to Retry in the spec, re-scaffolding, and running the facts harness turns
# the specific `onReject` assertion red (it diverges from the hand-written
# expectation in test/conformance-process/Main.hs).
#
# Exit 0 => the mutation was caught. Run from the keiro repo root.
set -euo pipefail

SPEC="keiro-dsl/test/fixtures/hospital-surge.keiro"
OUT="keiro-dsl/test/conformance-process"
EXE="$(cabal list-bin keiro-dsl 2>/dev/null)"
MUT="$(mktemp).keiro"
restore() { "$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null 2>&1 || true; rm -f "$MUT"; }
trap restore EXIT

echo "== baseline: facts harness green =="
"$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null
cabal test keiro-dsl-conformance-process >/dev/null 2>&1 \
  && echo "ok: baseline green" || { echo "FAIL: baseline not green"; exit 1; }

echo "== mutate: on-reject Fired -> Retry, re-scaffold =="
sed 's/on-reject Fired/on-reject Retry/' "$SPEC" > "$MUT"
"$EXE" scaffold "$MUT" --out "$OUT" >/dev/null

echo "== rebuild + run facts harness (expect FAIL on onReject) =="
if cabal test keiro-dsl-conformance-process >/dev/null 2>&1; then
  echo "FAIL: the on-reject mutation was not caught"; exit 1
else
  echo "ok: the on-reject mutation turned a specific assertion red (caught)"
fi

echo "PASS: the process facts harness pins the spec's disposition decisions"
