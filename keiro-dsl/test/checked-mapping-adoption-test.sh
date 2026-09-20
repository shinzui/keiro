#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"

workspace="keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace"
committed="keiro-dsl/test/conformance-checked-mapping-replay"
scratch_parent="${TMPDIR:-/tmp}"
proof_root="$(mktemp -d "${scratch_parent%/}/keiro-checked-mapping-adoption.XXXXXX")"

cleanup() {
  case "$proof_root" in
    "${scratch_parent%/}"/keiro-checked-mapping-adoption.*) rm -rf -- "$proof_root" ;;
    *) printf 'refusing unsafe cleanup target: %s\n' "$proof_root" >&2 ;;
  esac
}
trap cleanup EXIT

hand_owned=(
  "Conformance/CheckedMappingReplay/Domain.hs"
  "Conformance/CheckedMappingReplay/Bindings.hs"
  "CheckedMappingReplay/ProjectionCatalog/ProjectionCatalogHoles.hs"
  "CheckedMappingReplay/ReplayLedger/BehaviorHoles.hs"
  "CheckedMappingReplay/ReplayLookup/ReadModelHoles.hs"
  "CheckedMappingReplay/ReplayReaction/ProcessHoles.hs"
  "CheckedMappingReplay/ReplayTarget/BehaviorHoles.hs"
)

hand_hashes() {
  local root="$1"
  local relative
  for relative in "${hand_owned[@]}"; do
    test -f "$root/$relative"
    shasum -a 256 "$root/$relative"
  done
}

copy_hand_owned() {
  local target="$1"
  local relative
  for relative in "${hand_owned[@]}"; do
    mkdir -p "$target/$(dirname "$relative")"
    cp "$committed/$relative" "$target/$relative"
  done
}

fresh="$proof_root/fresh"
existing="$proof_root/existing"
mkdir -p "$fresh" "$existing"

echo "checked-mapping adoption: public check"
cabal run -v0 keiro-dsl -- check "$workspace"

echo "checked-mapping adoption: fresh scaffold"
cabal run -v0 keiro-dsl -- scaffold "$workspace" --out "$fresh" >/dev/null
test -f "$fresh/Conformance/CheckedMappingReplay/Bindings.hs"
grep -q "HOLE" "$fresh/Conformance/CheckedMappingReplay/Bindings.hs"
copy_hand_owned "$fresh"
hand_hashes "$fresh" >"$proof_root/fresh.before"
cabal run -v0 keiro-dsl -- scaffold "$workspace" --out "$fresh" >/dev/null
hand_hashes "$fresh" >"$proof_root/fresh.after"
cmp "$proof_root/fresh.before" "$proof_root/fresh.after"
diff -ru "$committed/Generated" "$fresh/Generated"

echo "checked-mapping adoption: existing bindings and create-once files"
cp -R "$committed/." "$existing/"
hand_hashes "$existing" >"$proof_root/existing.before"
cabal run -v0 keiro-dsl -- scaffold "$workspace" --out "$existing" >/dev/null
hand_hashes "$existing" >"$proof_root/existing.after"
cmp "$proof_root/existing.before" "$proof_root/existing.after"
diff -ru "$committed/Generated" "$existing/Generated"

echo "checked-mapping adoption: compiled harness"
cabal test -v0 keiro-dsl:test:keiro-dsl-conformance-checked-mapping-replay --test-show-details=direct
echo "checked-mapping adoption: PASS"
