#!/usr/bin/env bash
# Integration test for `keiro-dsl diff --since` (EP-103).
#
# Proves the merge gate end-to-end against real git history across all three
# tiers and both axes: decode and identity changes block as BREAKING, safe
# additions remain ADDITIVE, and forward-policy changes print WARNING without
# blocking.
#
# Exit 0 => all classifications, codes, and process exit statuses are correct.
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

echo "== 5) contract event removal must be BREAKING =="
cp "$FIX/contract.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "contract baseline"
cp "$FIX/contract-eventdrop.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: contract event removal was not flagged breaking"; exit 1
elif [[ "$output" == *"[ContractEventRemoved]"* ]]; then
  echo "$output"
  echo "ok: contract event removal blocks the merge"
else
  echo "$output"
  echo "FAIL: contract event removal used the wrong diagnostic code"; exit 1
fi

echo "== 6) workflow stable-name rename must be BREAKING =="
cp "$FIX/workflow.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "workflow baseline"
cp "$FIX/workflow-rename.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: workflow stable-name rename was not flagged breaking"; exit 1
elif [[ "$output" == *"[WorkflowStableNameChanged]"* ]]; then
  echo "$output"
  echo "ok: workflow identity change blocks the merge"
else
  echo "$output"
  echo "FAIL: workflow rename used the wrong diagnostic code"; exit 1
fi

echo "== 7) id prefix change must be BREAKING =="
cp "$FIX/reservation.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "reservation identity baseline"
cp "$FIX/reservation-idprefix.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: id prefix change was not flagged breaking"; exit 1
elif [[ "$output" == *"[IdPrefixChanged]"* ]]; then
  echo "$output"
  echo "ok: id prefix change blocks the merge"
else
  echo "$output"
  echo "FAIL: id prefix change used the wrong diagnostic code"; exit 1
fi

echo "== 8) timer window change must WARNING and exit 0 =="
cp "$FIX/hospital-surge.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "timer baseline"
cp "$FIX/hospital-surge-window.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  if [[ "$output" == WARNING:* && "$output" == *"[TimerWindowChanged]"* ]]; then
    echo "$output"
    echo "ok: timer policy change is visible without blocking the merge"
  else
    echo "$output"
    echo "FAIL: timer window change did not print the expected WARNING"; exit 1
  fi
else
  echo "$output"
  echo "FAIL: timer window warning incorrectly blocked the merge"; exit 1
fi

echo "PASS: diff --since gates the decode and identity surface"
