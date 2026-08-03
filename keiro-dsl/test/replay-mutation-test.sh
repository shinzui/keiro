#!/usr/bin/env bash
# Mutation test for the generated forward/replay equality assertion (plan 147).
#
# The baseline uses the honest generated WireCtor. The mutation temporarily
# routes the generated transition through a dormant idempotent dishonest ctor
# that duplicates `echo` into both event fields. Static validation, codec
# round-trips, and the transition's final vertex still pass; only the replayed
# `note` register diverges.
set -euo pipefail

TRANSDUCER="keiro-dsl/test/conformance-replay/Generated/ReplayDivergence/Note/Transducer.hs"
BACKUP="$(mktemp)"
cp "$TRANSDUCER" "$BACKUP"
restore() {
  cp "$BACKUP" "$TRANSDUCER"
  rm -f "$BACKUP"
}
trap restore EXIT

echo "== baseline: harness is green =="
if cabal test keiro-dsl-conformance-replay >/dev/null 2>&1; then
  echo "ok: baseline green"
else
  echo "FAIL: baseline harness is not green"
  exit 1
fi

echo "== mutate: switch the generated emit to the dishonest wire ctor =="
sed -i.sed-bak \
  '/import Keiki.Symbolic qualified as S/a\
import ReplayDivergence.Note.Holes (dishonestWireNoteWritten)
' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
sed -i.sed-bak \
  's/B.emit wireNoteWritten/B.emit dishonestWireNoteWritten/' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"

echo "== rebuild + run harness (expect the register assertion red) =="
if MUTATION_OUTPUT="$(cabal test keiro-dsl-conformance-replay --test-show-details=direct 2>&1)"; then
  echo "$MUTATION_OUTPUT"
  echo "FAIL: the dishonest wire ctor was not caught by the harness"
  exit 1
fi
echo "$MUTATION_OUTPUT"

FAIL_LINES="$(printf '%s\n' "$MUTATION_OUTPUT" | grep '^FAIL  ' || true)"
EXPECTED_FAIL="FAIL  forward/replay equality: WriteNote from NoteEmpty -- register note"
if [[ "$FAIL_LINES" != "$EXPECTED_FAIL" ]]; then
  echo "FAIL: expected exactly one red register assertion"
  exit 1
fi

for EXPECTED_PASS in \
  "PASS  validateTransducer is empty" \
  "PASS  golden round-trip: NoteWritten" \
  "PASS  accepts WriteNote from NoteEmpty" \
  "PASS  forward/replay equality: WriteNote from NoteEmpty -- final vertex"; do
  if ! printf '%s\n' "$MUTATION_OUTPUT" | grep -Fq "$EXPECTED_PASS"; then
    echo "FAIL: expected still-green assertion missing: $EXPECTED_PASS"
    exit 1
  fi
done

echo "ok: the register assertion went red; validator, codec, accept, and vertex stayed green"
echo "PASS: forward/replay equality has teeth (mutation caught)"
