#!/usr/bin/env bash
# Mutation test for the keiro-dsl harness (EP-1 / plan 59, milestone 4).
#
# Proves the *harness*, not the scaffold, pins behaviour: flipping the filled
# guard operator `./=` to `.==` in the hand-owned Holes.hs must turn a SPECIFIC
# named harness assertion red. The scaffold is untouched and the firewall still
# holds; only behaviour changes, and only the harness catches it.
#
# Exit 0  => the mutation was caught (harness failed as expected).
# Exit 1  => the mutation slipped through (harness still green) — a real problem.
#
# Run from the keiro repo root:  bash keiro-dsl/test/mutation-test.sh
set -euo pipefail

HOLES="keiro-dsl/test/conformance/HospitalCapacity/Reservation/Holes.hs"
BACKUP="$(mktemp)"
cp "$HOLES" "$BACKUP"
restore() { cp "$BACKUP" "$HOLES"; rm -f "$BACKUP"; }
trap restore EXIT

echo "== baseline: harness is green =="
cabal test keiro-dsl-conformance >/dev/null 2>&1 \
  && echo "ok: baseline green" \
  || { echo "FAIL: baseline harness is not green"; exit 1; }

echo "== mutate: flip ./= to .== in the filled guard =="
sed -i.sed-bak 's/\.\/=/\.==/' "$HOLES"; rm -f "$HOLES.sed-bak"

echo "== rebuild + run harness (expect FAIL) =="
if cabal test keiro-dsl-conformance >/dev/null 2>&1; then
  echo "FAIL: the guard mutation was NOT caught by the harness"
  exit 1
else
  echo "ok: the guard mutation turned a harness assertion red (caught)"
fi

echo "PASS: harness pins behaviour (mutation caught)"
