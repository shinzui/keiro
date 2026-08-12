#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

catalog="keiro-dsl/test/conformance-projection-catalog/Generated/CatalogDemo/ProjectionCatalog.hs"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-projection-supply-mutation.XXXXXX")"
case "$backup_dir" in
  *keiro-projection-supply-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $backup_dir"; exit 1 ;;
esac

backup="$backup_dir/ProjectionCatalog.hs"
cp "$catalog" "$backup"
baseline_digest="$(shasum -a 256 "$catalog")"

restore_catalog() {
  cp "$backup" "$catalog"
}

cleanup() {
  restore_catalog
  rm -f "$backup_dir/mutation.log" "$backup"
  rmdir "$backup_dir"
}
trap cleanup EXIT

run_conformance() {
  cabal test -v0 keiro-dsl:keiro-dsl-conformance-projection-catalog --test-show-details=direct
}

expect_red() {
  local label="$1"
  local expected="$2"
  set +e
  run_conformance >"$backup_dir/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  if ! grep -Fq "$expected" "$backup_dir/mutation.log"; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: mutation missed its named gate: $label"
    exit 1
  fi
  echo "PASS: mutation turned its named gate red: $label"
  restore_catalog
}

echo "== baseline: projection supply conformance is green =="
run_conformance >/dev/null

perl -0pi -e 's/ordersInlineProjections = concat \[orderSummaryWriterInlineProjections\]/ordersInlineProjections = concat [orderSummaryWriterInlineProjections, orderSummaryWriterInlineProjections]/' "$catalog"
expect_red "emit one inline handler per query" "projection catalog conformance failed: source-selected inline handlers stay singular"

perl -0pi -e 's/projectionCatalogQuerySupplies = Catalog\.resolvedQuerySupplies validatedProjectionCatalog/projectionCatalogQuerySupplies = take 1 (Catalog.resolvedQuerySupplies validatedProjectionCatalog)/' "$catalog"
expect_red "select only the first resolved query supplier" "projection catalog conformance failed: generated read-model facts"

restore_catalog
if [[ "$(shasum -a 256 "$catalog")" != "$baseline_digest" ]]; then
  echo "FAIL: projection catalog was not restored byte-for-byte"
  exit 1
fi

run_conformance >/dev/null
echo "PASS: projection supply mutations were caught and exact bytes restored"
