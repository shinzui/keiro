#!/usr/bin/env bash
# Mutation sentinels for authoritative scalar expressions (plan 161).
set -euo pipefail

EXPRESSIONS="keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/ScalarAccount/Expressions.hs"
TRANSDUCER="keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/ScalarAccount/Transducer.hs"
HOLES="keiro-dsl/test/conformance-scalar-expressions/AggregateScalarExpressions/ScalarAccount/Holes.hs"
FIXTURE="keiro-dsl/test/fixtures/aggregate-scalar-expressions-v2.keiro"

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-scalar-mutation.XXXXXX")"
case "$BACKUP_DIR" in
  *keiro-scalar-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $BACKUP_DIR"; exit 1 ;;
esac

cp "$EXPRESSIONS" "$BACKUP_DIR/Expressions.hs"
cp "$TRANSDUCER" "$BACKUP_DIR/Transducer.hs"
cp "$HOLES" "$BACKUP_DIR/Holes.hs"
cp "$FIXTURE" "$BACKUP_DIR/fixture.keiro"

restore_all() {
  cp "$BACKUP_DIR/Expressions.hs" "$EXPRESSIONS"
  cp "$BACKUP_DIR/Transducer.hs" "$TRANSDUCER"
  cp "$BACKUP_DIR/Holes.hs" "$HOLES"
  cp "$BACKUP_DIR/fixture.keiro" "$FIXTURE"
}

cleanup() {
  restore_all
  rm -f "$BACKUP_DIR/Expressions.hs" "$BACKUP_DIR/Transducer.hs" "$BACKUP_DIR/Holes.hs" "$BACKUP_DIR/fixture.keiro" "$BACKUP_DIR/mutation.log"
  rmdir "$BACKUP_DIR"
}
trap cleanup EXIT

restore_file() {
  cp "$BACKUP_DIR/$1" "$2"
}

expect_red() {
  local label="$1"
  shift
  echo "== mutate: $label =="
  set +e
  "$@" >"$BACKUP_DIR/mutation.log" 2>&1
  mutation_status=$?
  set -e
  if [[ "$mutation_status" -eq 0 ]]; then
    sed -n '1,240p' "$BACKUP_DIR/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  echo "PASS: mutation turned its owning check red: $label"
}

run_conformance() {
  cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
}

echo "== baseline: scalar expression checks are green =="
run_conformance >/dev/null
cabal test keiro-dsl-test --test-option=--match --test-option='scalar expressions' >/dev/null

sed -i.sed-bak \
  's/K.tsub (d.requested) (B.reg @"capacity")/K.TApp2 (-) (d.requested) (B.reg @"capacity")/' \
  "$EXPRESSIONS"
rm -f "$EXPRESSIONS.sed-bak"
expect_red "Natural monus becomes partial subtraction" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Expressions.hs "$EXPRESSIONS"

sed -i.sed-bak \
  '/^transition1OpenAdjustGuard d = /c\
transition1OpenAdjustGuard _d = K.PTop' \
  "$EXPRESSIONS"
rm -f "$EXPRESSIONS.sed-bak"
expect_red "generated guard is bypassed" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Expressions.hs "$EXPRESSIONS"

sed -i.sed-bak \
  's/K.lit (2 :: Integer)/K.lit (3 :: Integer)/' \
  "$EXPRESSIONS"
rm -f "$EXPRESSIONS.sed-bak"
expect_red "generated write operand changes" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Expressions.hs "$EXPRESSIONS"

sed -i.sed-bak \
  '/^    implementation hole$/a\
    guard cmd.balance >= 0' \
  "$FIXTURE"
rm -f "$FIXTURE.sed-bak"
expect_red "Hole ownership coexists with a DSL guard" \
  cabal run -v0 keiro-dsl -- check "$FIXTURE"
restore_file fixture.keiro "$FIXTURE"

sed -i.sed-bak \
  '/B.emit wireClosedEvent/c\
        B.noEmit' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "Hole transition violates its declared event envelope" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Transducer.hs "$TRANSDUCER"

sed -i.sed-bak \
  's/B.goto ScalarAccountClosed/B.goto ScalarAccountReviewed/' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "Hole transition violates its declared target envelope" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Transducer.hs "$TRANSDUCER"

sed -i.sed-bak \
  's/transition2ReviewedCloseHoleFoldVersion/omittedTransition2ReviewedCloseHoleFoldVersion/g' \
  "$HOLES"
rm -f "$HOLES.sed-bak"
expect_red "Hole fold version is omitted" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Holes.hs "$HOLES"

sed -i.sed-bak \
  's/verifyTransition "transition2ReviewedClose" HoleOwned ScalarAccountReviewed 0/pure ("transition2ReviewedClose", HoleOwned, S.VerifiedSatisfiable)/' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "opaque Hole is falsely reported verified" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Transducer.hs "$TRANSDUCER"

restore_all
run_conformance >/dev/null
git diff --check
echo "PASS: all scalar expression mutations were detected and exact files restored"
