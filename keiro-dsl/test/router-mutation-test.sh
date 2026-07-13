#!/usr/bin/env bash
# Prove that changing one router policy in the spec reddens exactly the
# corresponding hand-written harness expectation.
set -euo pipefail

SPEC="keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro"
OUT="keiro-dsl/test/conformance-router"
EXE="$(cabal list-bin keiro-dsl 2>/dev/null)"
MUT="$(mktemp).keiro"
LOG="$(mktemp).log"
restore() {
  "$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null 2>&1 || true
  rm -f "$MUT" "$LOG"
}
trap restore EXIT

"$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null
cabal test keiro-dsl-conformance-router >/dev/null 2>&1

sed 's/rejected => deadLetter/rejected => halt/' "$SPEC" > "$MUT"
"$EXE" scaffold "$MUT" --out "$OUT" >/dev/null

if cabal test keiro-dsl-conformance-router --test-show-details=direct >"$LOG" 2>&1; then
  echo "FAIL: rejected-policy mutation was not caught"
  exit 1
fi

grep -F 'router harness: 1 assertion(s) failed: ["rejectedPolicy"]' "$LOG" >/dev/null
echo "mutated spec: rejectedPolicy assertion FAILED (expected)"

"$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null
cabal test keiro-dsl-conformance-router >/dev/null 2>&1
echo "restored spec: all router harness assertions green"
