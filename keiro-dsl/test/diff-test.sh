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
cp "$FIX/reservation.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "baseline v1 spec"

echo "== 1) field-add without bump must be BREAKING (exit != 0) =="
cp "$FIX/reservation-fieldadd.keiro" "$DEMO/svc.keiro"
if "$EXE" diff --since HEAD "$DEMO/svc.keiro"; then
  echo "FAIL: field-add was not flagged breaking"; exit 1
else
  echo "ok: flagged breaking, gate blocks the merge"
fi

echo "== 2) v2 + upcaster must be ADDITIVE (exit 0) =="
cp "$FIX/reservation-v2.keiro" "$DEMO/svc.keiro"
if "$EXE" diff --since HEAD "$DEMO/svc.keiro"; then
  echo "ok: additive, gate allows the merge"
else
  echo "FAIL: v2 + upcaster was wrongly flagged breaking"; exit 1
fi

echo "== 3) field type change must be BREAKING with EvtFieldTypeChanged =="
cp "$FIX/reservation-fieldtype.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: field type change was not flagged breaking"; exit 1
elif [[ "$output" == *"[EvtFieldTypeChanged]"* ]]; then
  echo "$output"
  echo "ok: field type change blocks the merge with the right code"
else
  echo "$output"
  echo "FAIL: field type change used the wrong diagnostic code"; exit 1
fi

echo "== 4) v1 -> v3 with only v2 upcaster must be BREAKING =="
cp "$FIX/reservation-v3-dangling.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: dangling upcaster jump was not flagged breaking"; exit 1
elif [[ "$output" == *"[EvtVersionMissingUpcaster]"* ]]; then
  echo "$output"
  echo "ok: dangling upcaster chain blocks the merge"
else
  echo "$output"
  echo "FAIL: dangling upcaster jump used the wrong diagnostic code"; exit 1
fi

echo "PASS: diff --since gates breaking event changes"
