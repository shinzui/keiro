#!/usr/bin/env bash
# Mutation sentinels for the authoritative inline scalar transducer.
set -euo pipefail

TRANSDUCER="keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/ScalarAccount/Transducer.hs"
HOLES="keiro-dsl/test/conformance-scalar-expressions/AggregateScalarExpressions/ScalarAccount/Holes.hs"
FIXTURE="keiro-dsl/test/fixtures/aggregate-scalar-expressions-v2.keiro"
CONFORMANCE_ROOT="keiro-dsl/test/conformance-scalar-expressions"

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-scalar-mutation.XXXXXX")"
case "$BACKUP_DIR" in
  *keiro-scalar-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $BACKUP_DIR"; exit 1 ;;
esac

cp "$TRANSDUCER" "$BACKUP_DIR/Transducer.hs"
cp "$HOLES" "$BACKUP_DIR/Holes.hs"
cp "$FIXTURE" "$BACKUP_DIR/fixture.keiro"
cp -R "$CONFORMANCE_ROOT" "$BACKUP_DIR/conformance-root"

restore_all() {
  cp -R "$BACKUP_DIR/conformance-root/." "$CONFORMANCE_ROOT/"
  cp "$BACKUP_DIR/fixture.keiro" "$FIXTURE"
}

cleanup() {
  restore_all
  rm -rf "$BACKUP_DIR/conformance-root"
  rm -f "$BACKUP_DIR/Transducer.hs" "$BACKUP_DIR/Holes.hs" "$BACKUP_DIR/fixture.keiro" "$BACKUP_DIR/mutation.log"
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
  's/d.requested .- B.reg @"capacity"/K.TApp2 (-) (d.requested) (B.reg @"capacity")/' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "Natural monus becomes partial subtraction" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Transducer.hs "$TRANSDUCER"

sed -i.sed-bak \
  '/^        B.requireGuard \$/c\
        B.requireGuard K.PTop' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "generated guard is bypassed" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
cabal run -v0 keiro-dsl -- scaffold "$FIXTURE" --out keiro-dsl/test/conformance-scalar-expressions >/dev/null
nix develop --command fourmolu -i \
  --ghc-opt -XGHC2024 \
  --ghc-opt -XImportQualifiedPost \
  --ghc-opt -XOverloadedLabels \
  "$TRANSDUCER" >/dev/null
run_conformance >/dev/null
cmp "$BACKUP_DIR/Transducer.hs" "$TRANSDUCER"
restore_file Transducer.hs "$TRANSDUCER"

sed -i.sed-bak \
  's/K.lit (2 :: Integer)/K.lit (3 :: Integer)/' \
  "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "generated write operand changes" cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
restore_file Transducer.hs "$TRANSDUCER"

sed -i.sed-bak \
  '/^    implementation hole$/a\
    guard cmd.balance >= 0' \
  "$FIXTURE"
rm -f "$FIXTURE.sed-bak"
expect_red "Hole ownership coexists with a DSL guard" \
  cabal run -v0 keiro-dsl -- check "$FIXTURE"
restore_file fixture.keiro "$FIXTURE"

sed -i.sed-bak \
  's/^          wireClosedEvent$/          wireAdjusted/' \
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
