#!/usr/bin/env bash
# Integration test for `keiro-dsl diff --since` (EP-2 / plan 60, milestone 2).
#
# Proves the merge gate end-to-end against real git history: a field added to an
# event without a version bump is BREAKING (exit != 0); wrapping the same field
# as a v2 with an upcaster hole is ADDITIVE (exit 0).
#
# Exit 0 => both classifications and exit codes are correct.
# Run from the keiro repo root:  bash keiro-dsl/test/diff-test.sh
set -euo pipefail

FIX="keiro-dsl/test/fixtures"
EXE="$(cabal list-bin keiro-dsl 2>/dev/null)"
DEMO="$(mktemp -d)"
cleanup() { rm -rf "$DEMO"; }
trap cleanup EXIT

git -C "$DEMO" init -q
cp "$FIX/reservation.kdsl" "$DEMO/svc.kdsl"
git -C "$DEMO" add svc.kdsl
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "baseline v1 spec"

echo "== 1) field-add without bump must be BREAKING (exit != 0) =="
cp "$FIX/reservation-fieldadd.kdsl" "$DEMO/svc.kdsl"
if "$EXE" diff --since HEAD "$DEMO/svc.kdsl"; then
  echo "FAIL: field-add was not flagged breaking"; exit 1
else
  echo "ok: flagged breaking, gate blocks the merge"
fi

echo "== 2) v2 + upcaster must be ADDITIVE (exit 0) =="
cp "$FIX/reservation-v2.kdsl" "$DEMO/svc.kdsl"
if "$EXE" diff --since HEAD "$DEMO/svc.kdsl"; then
  echo "ok: additive, gate allows the merge"
else
  echo "FAIL: v2 + upcaster was wrongly flagged breaking"; exit 1
fi

echo "PASS: diff --since gates breaking event changes"
