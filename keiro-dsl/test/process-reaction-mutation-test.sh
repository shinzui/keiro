#!/usr/bin/env bash
# Mutation proof for Language-6 process reactions and typed timers.
set -euo pipefail

REACTIONS_SPEC="keiro-dsl/test/fixtures/process-reactions.keiro"
REACTIONS_OUT="keiro-dsl/test/conformance-process-reactions"
REACTIONS_TEST="keiro-dsl:keiro-dsl-conformance-process-reactions"
TIMERS_SPEC="keiro-dsl/test/fixtures/process-timers.keiro"
TIMERS_OUT="keiro-dsl/test/conformance-process-timers"
TIMERS_TEST="keiro-dsl:keiro-dsl-conformance-process-timers"
EXE="$(cabal list-bin keiro-dsl 2>/dev/null)"
MUT="$(mktemp).keiro"
LOG="$(mktemp).log"

restore_all() {
  "$EXE" scaffold "$REACTIONS_SPEC" --out "$REACTIONS_OUT" >/dev/null 2>&1 || true
  "$EXE" scaffold "$TIMERS_SPEC" --out "$TIMERS_OUT" >/dev/null 2>&1 || true
  rm -f "$MUT" "$LOG"
}
trap restore_all EXIT

expect_runtime_failure() {
  local label="$1"
  local source="$2"
  local output="$3"
  local component="$4"

  "$EXE" scaffold "$MUT" --out "$output" >/dev/null 2>&1
  if cabal test "$component" --test-show-details=direct >"$LOG" 2>&1; then
    echo "FAIL: $label mutation was not caught"
    exit 1
  fi
  echo "ok: $label mutation reddened generated conformance"
  "$EXE" scaffold "$source" --out "$output" >/dev/null 2>&1
  cabal test "$component" >/dev/null 2>&1
}

echo "== baseline reaction conformance =="
restore_all
cabal test "$REACTIONS_TEST" "$TIMERS_TEST" >/dev/null 2>&1

sed 's/input.severity == Severity.Sev1/input.severity != Severity.Sev1/' "$REACTIONS_SPEC" >"$MUT"
expect_runtime_failure "guard operator" "$REACTIONS_SPEC" "$REACTIONS_OUT" "$REACTIONS_TEST"

sed 's/schedule escalation fireAt input.raisedAt + 5m { incidentId detail }/schedule escalation fireAt input.raisedAt + 5m { incidentId }/' "$TIMERS_SPEC" >"$MUT"
if "$EXE" check "$MUT" >"$LOG" 2>&1; then
  echo "FAIL: dynamic payload binding mutation was not caught"
  exit 1
fi
grep -F 'ProcessSchedulePayloadIncomplete' "$LOG" >/dev/null
echo "ok: missing dynamic payload binding was rejected"

sed 's/fire dispatch Incident@correlationId EscalateIncident/fire dispatch Incident@correlationId RemindIncident/' "$TIMERS_SPEC" >"$MUT"
expect_runtime_failure "dispatched command" "$TIMERS_SPEC" "$TIMERS_OUT" "$TIMERS_TEST"

sed 's/incident-escalation-timer:/incident-escalation-timer-mutated:/' "$TIMERS_SPEC" >"$MUT"
expect_runtime_failure "timer identity prefix" "$TIMERS_SPEC" "$TIMERS_OUT" "$TIMERS_TEST"

echo "PASS: reaction guards, payload bindings, dispatch commands, and timer identities are pinned"
