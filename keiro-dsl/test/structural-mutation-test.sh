#!/usr/bin/env bash
# Falsification evidence for plan 150's structural consumer conformance gates.
set -euo pipefail

BINDINGS="keiro-dsl/test/conformance-structural/Conformance/Structural/Bindings.hs"
HOLES="keiro-dsl/test/conformance-structural/StructuralConformance/ArtifactCatalog/Holes.hs"
BINDINGS_BACKUP="$(mktemp)"
HOLES_BACKUP="$(mktemp)"
cp "$BINDINGS" "$BINDINGS_BACKUP"
cp "$HOLES" "$HOLES_BACKUP"

restore() {
  cp "$BINDINGS_BACKUP" "$BINDINGS"
  cp "$HOLES_BACKUP" "$HOLES"
  rm -f "$BINDINGS_BACKUP" "$HOLES_BACKUP"
}
trap restore EXIT

restore_bindings() { cp "$BINDINGS_BACKUP" "$BINDINGS"; }
restore_holes() { cp "$HOLES_BACKUP" "$HOLES"; }

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
  echo "$output"
  if ! printf '%s\n' "$output" | grep -Eq "$expected"; then
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
expect_red "binding transpose" '^FAIL  binding domain round-trip: conformance\.structural\.ArtifactInfo\.v1/'
restore_bindings

echo "== mutate fixtures: remove the canonical union case =="
sed -i.sed-bak '/("canonical", Domain\.Canonical)/d' "$BINDINGS"
rm -f "$BINDINGS.sed-bak"
expect_red "missing union fixture" '^FAIL  fixture coverage: conformance\.structural\.ArtifactLocation\.v1$|^FAIL  wire union arm: conformance\.structural\.ArtifactLocation\.v1/canonical$'
restore_bindings

echo "== mutate event order: put the scalar-only event before the mapped event =="
sed -i.sed-bak 's/^        B\.emit wireArtifactRecorded .*$/        -- STRUCTURAL_MUTATION_RECORDED/' "$HOLES"
rm -f "$HOLES.sed-bak"
sed -i.sed-bak 's/^        B\.emit wireArtifactAccepted .*$/        B.emit wireArtifactAccepted ArtifactAcceptedTermFields{accepted = d.accepted}\n        B.emit wireArtifactRecorded ArtifactRecordedTermFields{artifact = d.artifact, geometry = d.geometry, accepted = d.accepted}/' "$HOLES"
rm -f "$HOLES.sed-bak"
sed -i.sed-bak '/STRUCTURAL_MUTATION_RECORDED/d' "$HOLES"
rm -f "$HOLES.sed-bak"
expect_red "first-event mapped-state omission" '^FAIL  validateTransducer is empty$|^FAIL  forward/replay equality: ObserveArtifact from ArtifactCatalogEmpty -- register currentArtifact$'
restore_holes

echo "== restored baseline: structural conformance is green =="
run_suite >/dev/null
echo "PASS: all three structural mutations were caught and the baseline was restored"
