#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bindings="keiro-dsl/test/conformance-mapped-readmodel/Conformance/MappedReadModel/Bindings.hs"
contract="keiro-dsl/test/conformance-mapped-readmodel/Generated/MappedReadmodel/AccountSummary/QueryContract.hs"
holes="keiro-dsl/test/conformance-mapped-readmodel/MappedReadmodel/AccountSummary/ReadModelHoles.hs"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-mapped-readmodel-mutation.XXXXXX")"
cp "$bindings" "$backup_dir/Bindings.hs"
cp "$contract" "$backup_dir/QueryContract.hs"
cp "$holes" "$backup_dir/ReadModelHoles.hs"

restore_all() {
  cp "$backup_dir/Bindings.hs" "$bindings"
  cp "$backup_dir/QueryContract.hs" "$contract"
  cp "$backup_dir/ReadModelHoles.hs" "$holes"
}

cleanup() {
  restore_all
  rm -f "$backup_dir/Bindings.hs" "$backup_dir/QueryContract.hs" "$backup_dir/ReadModelHoles.hs" "$backup_dir/mutation.log"
  rmdir "$backup_dir"
}
trap cleanup EXIT

expect_red() {
  local label="$1"
  set +e
  cabal test -v0 keiro-dsl:keiro-dsl-conformance-mapped-readmodel >"$backup_dir/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  echo "PASS: mutation turned the mapped read-model gate red: $label"
}

perl -0pi -e 's/import Conformance\.MappedReadModel\.Domain \(AccountLookup, AccountSummary\)/import Conformance.MappedReadModel.Domain (AccountSummary, UnusedFilter)/' "$contract"
expect_red "change the imported query input domain type"
restore_all

perl -0pi -e 's/\ntype AccountSummaryQueryResult = Maybe AccountSummary//' "$contract"
expect_red "delete the generated query result alias"
restore_all

perl -0pi -e 's/bindingToShape accountProfileBinding <\$> profile/bindingToShape tenantKeyBinding <\$> profile/' "$bindings"
expect_red "alter a nested result binding"
restore_all

perl -0pi -e 's/(import Hasql\.Transaction qualified as Tx\n)/$1\ntype AccountSummaryQueryInput = ()\n/' "$holes"
expect_red "restore a stale legacy query alias"
restore_all

cabal test -v0 keiro-dsl:keiro-dsl-conformance-mapped-readmodel
echo "PASS: mapped read-model mutations were caught and exact files restored"
