#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bindings="keiro-dsl/test/conformance-mapped-queue/Conformance/MappedQueue/Bindings.hs"
queue="keiro-dsl/test/conformance-mapped-queue/Generated/MappedQueue/MappedJobs/Queue.hs"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-mapped-queue-mutation.XXXXXX")"
cp "$bindings" "$backup_dir/Bindings.hs"
cp "$queue" "$backup_dir/Queue.hs"

restore_all() {
  cp "$backup_dir/Bindings.hs" "$bindings"
  cp "$backup_dir/Queue.hs" "$queue"
}

cleanup() {
  restore_all
  rm -f "$backup_dir/Bindings.hs" "$backup_dir/Queue.hs" "$backup_dir/mutation.log"
  rmdir "$backup_dir"
}
trap cleanup EXIT

expect_red() {
  local label="$1"
  set +e
  cabal test -v0 keiro-dsl:keiro-dsl-conformance-mapped-queue >"$backup_dir/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  echo "PASS: mutation turned the mapped queue gate red: $label"
}

perl -0pi -e 's/value\.jobId\n          value\.label/value.label\n          value.jobId/' "$bindings"
expect_red "transpose the total structural binding"
restore_all

perl -0pi -e 's/\n      , "geometry" \.= toJSON \(ShapeJobPayload\.geometry shape\)//' "$queue"
expect_red "remove the nested queue field encoder"
restore_all

perl -0pi -e 's/\n    <\*> explicitParseField \(parseJSON\) objectValue "geometry"//' "$queue"
expect_red "remove the nested queue field decoder"
restore_all

cabal test -v0 keiro-dsl:keiro-dsl-conformance-mapped-queue
echo "PASS: mapped queue mutations were caught and exact files restored"
