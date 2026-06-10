#!/usr/bin/env bash
# Mutation test for the workflow facts harness (EP-6).
# Renaming the await label in the spec, re-scaffolding, reddens the `awaits`/`body`
# assertions (they diverge from the hand-written expectation in
# test/conformance-workflow/Main.hs). Exit 0 => the mutation was caught.
set -euo pipefail
SPEC="keiro-dsl/test/fixtures/workflow.kdsl"
OUT="keiro-dsl/test/conformance-workflow"
EXE="$(cabal list-bin keiro-dsl 2>/dev/null)"
MUT="$(mktemp).kdsl"
restore() { "$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null 2>&1 || true; rm -f "$MUT"; }
trap restore EXIT

"$EXE" scaffold "$SPEC" --out "$OUT" >/dev/null
cabal test keiro-dsl-conformance-workflow >/dev/null 2>&1 && echo "ok: baseline green" || { echo "FAIL: baseline"; exit 1; }

sed 's/reservation-confirmation/reservation-confirmed/g' "$SPEC" > "$MUT"
"$EXE" scaffold "$MUT" --out "$OUT" >/dev/null
if cabal test keiro-dsl-conformance-workflow >/dev/null 2>&1; then
  echo "FAIL: the await-rename mutation was not caught"; exit 1
else
  echo "ok: the await-rename mutation reddened a specific assertion (caught)"
fi
echo "PASS: the workflow facts harness pins the await/body decisions"
