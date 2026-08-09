#!/usr/bin/env bash
# Falsification evidence for plans 150 and 151's structural consumer gates.
set -euo pipefail

BINDINGS="keiro-dsl/test/conformance-structural/Conformance/Structural/Bindings.hs"
TRANSDUCER="keiro-dsl/test/conformance-structural/Generated/StructuralConformance/ArtifactCatalog/Transducer.hs"
BINDINGS_BACKUP="$(mktemp)"
TRANSDUCER_BACKUP="$(mktemp)"
cp "$BINDINGS" "$BINDINGS_BACKUP"
cp "$TRANSDUCER" "$TRANSDUCER_BACKUP"

restore() {
  cp "$BINDINGS_BACKUP" "$BINDINGS"
  cp "$TRANSDUCER_BACKUP" "$TRANSDUCER"
  rm -f "$BINDINGS_BACKUP" "$TRANSDUCER_BACKUP"
}
trap restore EXIT

restore_bindings() { cp "$BINDINGS_BACKUP" "$BINDINGS"; }
restore_transducer() { cp "$TRANSDUCER_BACKUP" "$TRANSDUCER"; }

run_suite() {
  cabal test keiro-dsl-conformance-structural --test-show-details=direct 2>&1
}

expect_red() {
  local mutation="$1"
  local expected="$2"
  local output
  if output="$(run_suite)"; then
    echo "$output"
    echo "FAIL: $mutation was not caught"
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -Eq "$expected"; then
    echo "$output"
    echo "FAIL: $mutation failed, but not through its expected structural gate"
    exit 1
  fi
  echo "ok: $mutation turned its structural gate red"
}

echo "== baseline: structural conformance is green =="
run_suite >/dev/null
echo "ok: baseline green"

echo "== mutate binding: transpose the artifact key and display name =="
sed -i.sed-bak '0,/value\.artifactKey/s//value.displayName/' "$BINDINGS"
rm -f "$BINDINGS.sed-bak"
expect_red "binding transpose" '^FAIL  structural/binding domain round-trip: conformance\.structural\.ArtifactInfo\.v1/'
restore_bindings

echo "== mutate skeleton fill: swap two union constructors in an explicit binding =="
sed -i.sed-bak 's/^artifactLocationBinding = genericStructuralBinding$/artifactLocationBinding = StructuralBinding { bindingToShape = \\case { Domain.LocalFile path -> LocationShape.LocalDir path; Domain.LocalDir path -> LocationShape.LocalFile path; Domain.RepoPath path -> LocationShape.RepoPath path; Domain.LocUrl url -> LocationShape.LocUrl url; Domain.Canonical -> LocationShape.Canonical }, bindingFromShape = \\case { LocationShape.LocalFile path -> Domain.LocalFile path; LocationShape.LocalDir path -> Domain.LocalDir path; LocationShape.RepoPath path -> Domain.RepoPath path; LocationShape.LocUrl url -> Domain.LocUrl url; LocationShape.Canonical -> Domain.Canonical } }/' "$BINDINGS"
rm -f "$BINDINGS.sed-bak"
expect_red "wrong skeleton union fill" '^FAIL  structural/binding domain round-trip: conformance\.structural\.ArtifactLocation\.v1/local-file$|^FAIL  structural/binding domain round-trip: conformance\.structural\.ArtifactLocation\.v1/local-dir$'
restore_bindings

echo "== mutate fixtures: remove the canonical union case =="
sed -i.sed-bak '/("canonical", Domain\.Canonical)/d' "$BINDINGS"
rm -f "$BINDINGS.sed-bak"
expect_red "missing union fixture" '^FAIL  structural/fixture coverage: conformance\.structural\.ArtifactLocation\.v1$'
restore_bindings

echo "== mutate event stream: omit the mapped-state event =="
sed -i.sed-bak '/^        B\.emit wireArtifactRecorded /,/^          })$/c\
        B.noEmit' "$TRANSDUCER"
rm -f "$TRANSDUCER.sed-bak"
expect_red "mapped-state event omission" '^FAIL  validateTransducer is empty$|^FAIL  forward/replay equality: ObserveArtifact from ArtifactCatalogEmpty -- replay succeeds$'
restore_transducer

echo "== restored baseline: structural conformance is green =="
run_suite >/dev/null
echo "PASS: all four structural mutations were caught and the baseline was restored"
