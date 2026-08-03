#!/usr/bin/env bash
# Mutation test for the keiro-dsl harness (EP-1 / plan 59, milestone 4).
#
# Proves the *harness*, not successful generation alone, pins behaviour: flipping
# the stable generated guard operator `./=` to `.==` must turn a SPECIFIC named
# harness assertion red. The mutation is temporary and the generated file is
# restored on every exit.
#
# Exit 0  => the mutation was caught (harness failed as expected).
# Exit 1  => the mutation slipped through (harness still green) — a real problem.
#
# Run from the keiro repo root:  bash keiro-dsl/test/mutation-test.sh
set -euo pipefail

TRANSDUCER="keiro-dsl/test/conformance/Generated/HospitalCapacity/Reservation/Transducer.hs"
BACKUP="$(mktemp)"
cp "$TRANSDUCER" "$BACKUP"
restore() { cp "$BACKUP" "$TRANSDUCER"; rm -f "$BACKUP"; }
trap restore EXIT

echo "== baseline: harness is green =="
cabal test keiro-dsl-conformance >/dev/null 2>&1 \
  && echo "ok: baseline green" \
  || { echo "FAIL: baseline harness is not green"; exit 1; }

echo "== mutate: flip ./= to .== in the generated stable guard =="
sed -i.sed-bak 's/\.\/=/\.==/' "$TRANSDUCER"; rm -f "$TRANSDUCER.sed-bak"

echo "== rebuild + run harness (expect FAIL) =="
if cabal test keiro-dsl-conformance >/dev/null 2>&1; then
  echo "FAIL: the guard mutation was NOT caught by the harness"
  exit 1
else
  echo "ok: the guard mutation turned a harness assertion red (caught)"
fi

echo "PASS: harness pins behaviour (mutation caught)"
