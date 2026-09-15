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
  if [[ "$output" == *"WARNING:"* && "$output" == *"[TimerWindowChanged]"* ]]; then
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
ADOPTION_REPORT="$ADOPTION/adoption-report.json"
if output="$("$EXE" diff --since HEAD --report-out "$ADOPTION_REPORT" "$ADOPTION/service.keiro-workspace" 2>&1)" \
    && [[ "$output" == *"workspace adoption baseline:"* \
    && "$output" == *"replay-neutral:"* ]] \
    && grep -q '"adoptionBaseline":true' "$ADOPTION_REPORT"; then
  echo "$output"
  echo "ok: adoption diffs existing member blobs even before the manifest is committed"
else
  echo "$output"
  echo "FAIL: adoption baseline did not compose the old service"; exit 1
fi

echo "== 14) shared workspace changes cite every member and emit one service report =="
CITATIONS="$DEMO/workspace-citations"
mkdir -p "$CITATIONS"
cp -R "$FIX/workspace-diff-old/." "$CITATIONS/"
git -C "$DEMO" add workspace-citations
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "workspace citation baseline"
cp -R "$FIX/workspace-diff-new/." "$CITATIONS/"
WORKSPACE_REPORT="$CITATIONS/workspace-report.json"
WORKSPACE_COVERAGE="$CITATIONS/workspace-coverage.json"
if output="$("$EXE" diff --since HEAD --report-out "$WORKSPACE_REPORT" --coverage-report "$WORKSPACE_COVERAGE" "$CITATIONS/service.keiro-workspace" 2>&1)"; then
  echo "$output"
  echo "FAIL: shared mapped wire change did not block"; exit 1
elif [[ "$output" == *"declared: domain/shared.keiro:4"* \
    && "$output" == *"use-site: Order"* \
    && "$output" == *"use-site: Shipment"* \
    && "$output" == *"semantic impact:"* \
    && "$output" == *"replay-affected:"* \
    && -s "$WORKSPACE_REPORT" \
    && -s "$WORKSPACE_COVERAGE" ]] \
    && grep -q '"schema":"keiro-dsl/diff-report/1"' "$WORKSPACE_REPORT" \
    && grep -q '"identity":"workspace-diff"' "$WORKSPACE_REPORT" \
    && grep -q '"semanticImpact":{"declarations":' "$WORKSPACE_REPORT" \
    && grep -q '"declaration":' "$WORKSPACE_REPORT" \
    && grep -q '"useSites":' "$WORKSPACE_REPORT"; then
  echo "$output"
  echo "ok: whole-service findings, replay impact, coverage, and report share one merged graph"
else
  echo "$output"
  echo "FAIL: whole-service citations or unified reports were incomplete"; exit 1
fi

echo "== 15) relative workspace golden roots resolve beside the manifest =="
WORKSPACE_GOLDENS="$DEMO/workspace-goldens"
mkdir -p "$WORKSPACE_GOLDENS"
cp "$FIX/reservation.keiro" "$WORKSPACE_GOLDENS/reservation.keiro"
printf 'service reservation-goldens\nspec reservation.keiro\n' > "$WORKSPACE_GOLDENS/service.keiro-workspace"
git -C "$DEMO" add workspace-goldens
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "workspace golden baseline"
cp "$FIX/reservation-v2.keiro" "$WORKSPACE_GOLDENS/reservation.keiro"
if output="$("$EXE" diff --since HEAD --emit-goldens golden-payloads "$WORKSPACE_GOLDENS/service.keiro-workspace" 2>&1)" \
    && [[ "$output" == *"golden: wrote synthesized weak stand-in"* \
    && -s "$WORKSPACE_GOLDENS/golden-payloads/hospital-capacity/Reservation/TransferReservationCreated.v1.json" ]]; then
  echo "$output"
  echo "ok: relative golden output is manifest-adjacent"
else
  echo "$output"
  echo "FAIL: workspace golden output did not use the manifest-adjacent root"; exit 1
fi

echo "== 16) moving an unchanged aggregate is ownership-only and non-blocking =="
MOVES="$DEMO/workspace-moves"
mkdir -p "$MOVES"
cp -R "$FIX/workspace-diff-old/." "$MOVES/"
git -C "$DEMO" add workspace-moves
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "workspace ownership baseline"
cp -R "$FIX/workspace-diff-moved/." "$MOVES/"
if output="$("$EXE" diff --since HEAD "$MOVES/service.keiro-workspace" 2>&1)" \
    && [[ "$output" == *"[OwnershipMoved]"* \
    && "$output" == *"domain/shipment.keiro -> domain/order.keiro"* \
    && "$output" != *"BREAKING:"* \
    && "$output" != *"ADDITIVE:"* ]]; then
  echo "$output"
  echo "ok: ownership motion is visible without wire churn or a failing gate"
else
  echo "$output"
  echo "FAIL: unchanged ownership motion was hidden, blocking, or misclassified"; exit 1
fi

echo "== 17) identical sibling transition families cancel before guard classification =="
FAMILY="$DEMO/transition-family"
mkdir -p "$FAMILY"
cp "$FIX/transition-family.keiro" "$FAMILY/service.keiro"
git -C "$DEMO" add transition-family/service.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "transition family baseline"
FAMILY_REPORT="$FAMILY/diff-report.json"
FAMILY_REPLAY="$FAMILY/replay-impact.json"
if output="$("$EXE" diff --since HEAD --report-out "$FAMILY_REPORT" --replay-impact-out "$FAMILY_REPLAY" "$FAMILY/service.keiro" 2>&1)" \
    && grep -q '"findings":\[\]' "$FAMILY_REPORT" \
    && grep -q '"verdict":"replay-neutral"' "$FAMILY_REPLAY" \
    && [[ "$output" != *"[AggGuardTightened]"* \
    && "$output" != *"[AggGuardRelationUnknown]"* \
    && "$output" != *"replay-only Active -- ObserveDescription"* ]]; then
  echo "$output"
  echo "ok: identical transition siblings cancel before guard classification"
else
  echo "$output"
  echo "FAIL: identical transition siblings produced guard or replay noise"; exit 1
fi

echo "== 18) ambiguous sibling families are advisory by default and selectively deniable =="
AMBIGUOUS="$DEMO/transition-family-ambiguous"
mkdir -p "$AMBIGUOUS"
cp "$FIX/transition-family-ambiguous-old.keiro" "$AMBIGUOUS/service.keiro"
git -C "$DEMO" add transition-family-ambiguous/service.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "ambiguous transition family baseline"
cp "$FIX/transition-family-ambiguous-new.keiro" "$AMBIGUOUS/service.keiro"
AMBIGUOUS_REPORT="$AMBIGUOUS/diff-report.json"
if output="$("$EXE" diff --since HEAD --report-out "$AMBIGUOUS_REPORT" "$AMBIGUOUS/service.keiro" 2>&1)" \
    && [[ "$output" == *"[AggGuardRelationUnknown]"* \
    && "$output" != *$'\n\nreplay-only Active -- ObserveDescription'* ]] \
    && grep -q 'do not deploy until the transition-family ambiguity is resolved' "$AMBIGUOUS_REPORT"; then
  echo "$output"
  echo "ok: ambiguous transition family stays advisory and carries stop-deployment guidance"
else
  echo "$output"
  echo "FAIL: ambiguous transition family was hidden, blocking by default, or given a fabricated twin"; exit 1
fi
if output="$("$EXE" diff --since HEAD --deny AggGuardRelationUnknown "$AMBIGUOUS/service.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: selective denial did not reject AggGuardRelationUnknown"; exit 1
elif [[ "$output" == *"[AggGuardRelationUnknown]"* \
    && "$output" == *"denied: AggGuardRelationUnknown"* ]]; then
  echo "$output"
  echo "ok: --deny AggGuardRelationUnknown blocks the ambiguous change"
else
  echo "$output"
  echo "FAIL: selective denial failed for the wrong reason"; exit 1
fi

echo "== 19) whole-body coverage distinguishes exact and partial replay twins =="
GUARD_BODY="$DEMO/guard-body"
mkdir -p "$GUARD_BODY"
cp "$FIX/reservation.keiro" "$GUARD_BODY/service.keiro"
git -C "$DEMO" add guard-body/service.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "guard body baseline"
cp "$FIX/reservation-guard-tightened.keiro" "$GUARD_BODY/service.keiro"
GUARD_BODY_REPORT="$GUARD_BODY/diff-report.json"
if output="$("$EXE" diff --since HEAD --report-out "$GUARD_BODY_REPORT" "$GUARD_BODY/service.keiro" 2>&1)" \
    && [[ "$output" == *"[AggGuardTightened]"* \
    && "$output" == *"replay-only Unrequested -- RequestTransferReservation"* ]] \
    && grep -q '"code":"AggGuardTightened"' "$GUARD_BODY_REPORT" \
    && grep -q 'add the computed replay-only edge' "$GUARD_BODY_REPORT"; then
  echo "$output"
  echo "ok: changed replay body advertises one validated twin"
else
  echo "$output"
  echo "FAIL: changed replay body did not advertise its validated twin"; exit 1
fi
cp "$FIX/reservation-guard-tightened-twin.keiro" "$GUARD_BODY/service.keiro"
if output="$("$EXE" diff --since HEAD "$GUARD_BODY/service.keiro" 2>&1)" \
    && [[ "$output" != *"[AggGuardTightened]"* \
    && "$output" != *"[AggGuardRemedyUnavailable]"* ]]; then
  echo "$output"
  echo "ok: exact computed twin covers the complete removed region"
else
  echo "$output"
  echo "FAIL: exact replay twin did not suppress the guard-history finding"; exit 1
fi
cp "$FIX/reservation-guard-tightened-partial-twin.keiro" "$GUARD_BODY/service.keiro"
if output="$("$EXE" diff --since HEAD "$GUARD_BODY/service.keiro" 2>&1)" \
    && [[ "$output" == *"[AggGuardTightened]"* ]]; then
  echo "$output"
  echo "ok: partial replay twin does not claim whole-body coverage"
else
  echo "$output"
  echo "FAIL: partial replay twin incorrectly suppressed the hazard"; exit 1
fi

echo "== 20) unavailable remedies stay advisory and are selectively deniable =="
UNAVAILABLE="$DEMO/guard-remedy-unavailable"
mkdir -p "$UNAVAILABLE"
cp "$FIX/guard-remedy-unavailable-old.keiro" "$UNAVAILABLE/service.keiro"
git -C "$DEMO" add guard-remedy-unavailable/service.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm "guard remedy unavailable baseline"
cp "$FIX/guard-remedy-unavailable-new.keiro" "$UNAVAILABLE/service.keiro"
UNAVAILABLE_REPORT="$UNAVAILABLE/diff-report.json"
if output="$("$EXE" diff --since HEAD --report-out "$UNAVAILABLE_REPORT" "$UNAVAILABLE/service.keiro" 2>&1)" \
    && [[ "$output" == *"[AggGuardRemedyUnavailable]"* \
    && "$output" != *$'\n\nreplay-only Open -- Close'* ]] \
    && grep -q 'do not deploy until the replay-only remedy validates' "$UNAVAILABLE_REPORT"; then
  echo "$output"
  echo "ok: invalid inserted twin is withheld with explicit guidance"
else
  echo "$output"
  echo "FAIL: unavailable remedy was hidden, blocking by default, or printed as paste-ready"; exit 1
fi
if output="$("$EXE" diff --since HEAD --deny AggGuardRemedyUnavailable "$UNAVAILABLE/service.keiro" 2>&1)"; then
  echo "$output"
  echo "FAIL: selective denial did not reject AggGuardRemedyUnavailable"; exit 1
elif [[ "$output" == *"[AggGuardRemedyUnavailable]"* \
    && "$output" == *"denied: AggGuardRemedyUnavailable"* ]]; then
  echo "$output"
  echo "ok: --deny AggGuardRemedyUnavailable blocks the unproved remedy"
else
  echo "$output"
  echo "FAIL: unavailable-remedy denial failed for the wrong reason"; exit 1
fi

echo "PASS: diff --since gates single specs and whole workspaces with owned unified reports"
