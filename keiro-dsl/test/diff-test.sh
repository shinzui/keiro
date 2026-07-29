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
if "$EXE" diff --since HEAD --gate old-binary-read-new-events "$DEMO/svc.keiro"; then
  echo "FAIL: adding a gate weakened the field-add result"; exit 1
else
  echo "ok: extra gates only add strictness"
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

echo "== 9) compatibility matrix must expose private, snapshot, and public surfaces =="
cp "$FIX/compatibility-vector-old.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "compatibility-vector baseline"
cp "$FIX/compatibility-vector-new.keiro" "$DEMO/svc.keiro"
REPORT="$DEMO/compatibility-report.json"
if output="$("$EXE" diff --since HEAD --explain --report-out "$REPORT" "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: public contract break in the compatibility matrix did not block"; exit 1
elif [[ "$output" == *"old-binary-read-new-events=breaking"* \
    && "$output" == *"snapshot-hydration=advisory"* \
    && "$output" == *"public-consumer=breaking"* \
    && "$output" == *"Reservation.event.TransferReservationCreated.patientAcuity"* \
    && -s "$REPORT" ]] \
    && grep -q '"schema":"keiro-dsl/diff-report/1"' "$REPORT"; then
  echo "$output"
  echo "ok: compatibility vector, explanations, paths, and JSON report are explicit"
else
  echo "$output"
  echo "FAIL: compatibility matrix omitted a surface, path, explanation, or report"; exit 1
fi

echo "== 10) mapped nested wire changes block while Haskell-only changes do not =="
cp "$FIX/consumer-types.keiro" "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "mapped consumer baseline"
cp "$FIX/consumer-types-fieldadd-nodefault.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: mapped field-add without default was not flagged breaking"; exit 1
elif [[ "$output" == *"[MappedFieldAddedNoDefault]"* \
    && "$output" == *"Catalog event ArtifactObserved"* \
    && "$output" == *"Catalog register currentArtifact"* ]]; then
  echo "$output"
  echo "ok: mapped field change names event migration and snapshot invalidation roots"
else
  echo "$output"
  echo "FAIL: mapped field change omitted its code or complete root paths"; exit 1
fi
cp "$FIX/consumer-types-haskell-rename.keiro" "$DEMO/svc.keiro"
if output="$("$EXE" diff --since HEAD "$DEMO/svc.keiro" 2>&1)"; then
  if [[ "$output" == *"[MappedHaskellSourceChanged]"* ]]; then
    echo "$output"
    echo "ok: Haskell-only rename is advisory and does not block"
  else
    echo "$output"
    echo "FAIL: Haskell-only rename omitted its source/build advisory"; exit 1
  fi
else
  echo "$output"
  echo "FAIL: Haskell-only mapped rename incorrectly blocked the merge"; exit 1
fi

echo "== 11) mapped version bump emits a nested weak stand-in without overwriting evidence =="
cp "$FIX/consumer-types-v2.keiro" "$DEMO/svc.keiro"
GOLDEN_ROOT="$DEMO/golden-payloads"
GOLDEN_PATH="$GOLDEN_ROOT/consumer-demo/Catalog/ArtifactObserved.v1.json"
if output="$("$EXE" diff --since HEAD --emit-goldens "$GOLDEN_ROOT" "$DEMO/svc.keiro" 2>&1)" \
    && [[ "$output" == *"golden: wrote synthesized weak stand-in"* \
    && -s "$GOLDEN_PATH" ]] \
    && grep -q '"location":{"contents":"sample","tag":"local_file"}' "$GOLDEN_PATH"; then
  echo "$output"
  echo "ok: nested old shape emitted and explicitly labelled weak evidence"
else
  echo "$output"
  echo "FAIL: mapped version bump did not emit the labelled nested golden"; exit 1
fi
printf 'hand captured\n' > "$GOLDEN_PATH"
if output="$("$EXE" diff --since HEAD --emit-goldens "$GOLDEN_ROOT" "$DEMO/svc.keiro" 2>&1)" \
    && [[ "$output" != *"golden: wrote"* \
    && "$(cat "$GOLDEN_PATH")" == "hand captured" ]]; then
  echo "ok: existing hand-captured evidence was preserved and omitted from writes"
else
  echo "$output"
  echo "FAIL: golden emission overwrote or re-reported existing evidence"; exit 1
fi

echo "== 12) workspace diff resolves manifest and members from git blobs =="
WORKSPACE="$DEMO/workspace-diff"
mkdir -p "$WORKSPACE"
cp "$FIX/reservation.keiro" "$WORKSPACE/reservation.keiro"
printf 'service reservation-service\nspec reservation.keiro\n' > "$WORKSPACE/service.keiro-workspace"
git -C "$DEMO" add workspace-diff
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "workspace diff baseline"
cp "$FIX/reservation-fieldadd.keiro" "$WORKSPACE/reservation.keiro"
if output="$("$EXE" diff --since HEAD "$WORKSPACE/service.keiro-workspace" 2>&1)"; then
  echo "$output"
  echo "FAIL: whole-workspace field addition was not flagged breaking"; exit 1
elif [[ "$output" == *"[EvtFieldAddedWithoutBump]"* ]]; then
  echo "$output"
  echo "ok: workspace manifest and old member blob resolve as one historical service"
else
  echo "$output"
  echo "FAIL: workspace diff used the wrong classification"; exit 1
fi

echo "== 13) workspace adoption baseline uses current members' old blobs =="
ADOPTION="$DEMO/workspace-adoption"
mkdir -p "$ADOPTION"
cp "$FIX/reservation.keiro" "$ADOPTION/reservation.keiro"
git -C "$DEMO" add workspace-adoption/reservation.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "pre-workspace member baseline"
printf 'service reservation-adoption\nspec reservation.keiro\n' > "$ADOPTION/service.keiro-workspace"
if output="$("$EXE" diff --since HEAD "$ADOPTION/service.keiro-workspace" 2>&1)" \
    && [[ "$output" == *"workspace adoption baseline:"* \
    && "$output" == *"replay-neutral:"* ]]; then
  echo "$output"
  echo "ok: adoption diffs existing member blobs even before the manifest is committed"
else
  echo "$output"
  echo "FAIL: adoption baseline did not compose the old service"; exit 1
fi

echo "PASS: diff --since gates single specs and whole workspaces without weakening existing breaks"
