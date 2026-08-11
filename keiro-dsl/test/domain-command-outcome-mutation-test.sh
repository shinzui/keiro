#!/usr/bin/env bash
# Falsification evidence for ExecPlan 232's typed domain outcome contract.
set -euo pipefail

FIXTURE="keiro-dsl/test/fixtures/domain-command-outcomes.keiro"
EVENT_STREAM="keiro-dsl/test/conformance-domain-outcomes/Generated/DomainOutcomes/Reservation/EventStream.hs"

backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-domain-outcome-mutation.XXXXXX")"
case "$backup_dir" in
  *keiro-domain-outcome-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $backup_dir"; exit 1 ;;
esac

cp "$EVENT_STREAM" "$backup_dir/EventStream.hs"

restore_event_stream() {
  cp "$backup_dir/EventStream.hs" "$EVENT_STREAM"
}

cleanup() {
  restore_event_stream
  rm -f "$backup_dir/EventStream.hs" "$backup_dir/fixture.keiro" "$backup_dir/mutation.log"
  rmdir "$backup_dir"
}
trap cleanup EXIT

run_conformance() {
  cabal test -v0 keiro-dsl:keiro-dsl-conformance-domain-outcomes --test-show-details=direct
}

expect_conformance_red() {
  local label="$1"
  local expected="$2"
  set +e
  run_conformance >"$backup_dir/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]] || ! grep -Fq "$expected" "$backup_dir/mutation.log"; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: $label did not fail through $expected"
    exit 1
  fi
  echo "ok: $label -> $expected"
}

expect_check_red() {
  local label="$1"
  local expected="$2"
  set +e
  cabal run -v0 keiro-dsl -- check "$backup_dir/fixture.keiro" --min-language 5 >"$backup_dir/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]] || ! grep -Fq "error[$expected]" "$backup_dir/mutation.log"; then
    sed -n '1,240p' "$backup_dir/mutation.log"
    echo "FAIL: $label did not fail through $expected"
    exit 1
  fi
  echo "ok: $label -> $expected"
}

echo "== baseline exact-reason conformance =="
run_conformance >/dev/null

perl -0pi -e 's/K\.lit AlreadyCancelled/K.lit CapacityUnavailable/' "$EVENT_STREAM"
expect_conformance_red "change the selected rejection reason" "domain-rejection-reason"
restore_event_stream

perl -0pi -e 's/SilentRejected \(K\.evalTerm \(K\.lit AlreadyCancelled\) registers command\)/SilentNoOp (K.evalTerm (K.lit DuplicateRequest) registers command)/' "$EVENT_STREAM"
expect_conformance_red "change a selected rejection to no-op" "domain-outcome-kind"
restore_event_stream

cp "$FIXTURE" "$backup_dir/fixture.keiro"
perl -0pi -e 's/    outcome accepted\n//' "$backup_dir/fixture.keiro"
expect_check_red "remove an outcome clause" "DomainOutcomeClauseMissing"

cp "$FIXTURE" "$backup_dir/fixture.keiro"
perl -0pi -e 's/  CancelledState -- Cancel -->\n    guard cmd\.requestId !=/  replay-only CancelledState -- Cancel -->\n    guard cmd.requestId !=/' "$backup_dir/fixture.keiro"
expect_check_red "attach an outcome to replay-only" "DomainOutcomeReplayOnlyClause"

cp "$FIXTURE" "$backup_dir/fixture.keiro"
perl -0pi -e 's/(    outcome rejected ReservationRejection\.AlreadyCancelled\n)/$1    emit Cancelled\n/' "$backup_dir/fixture.keiro"
expect_check_red "emit from a rejection" "DomainOutcomeSilentEmits"

cp "$FIXTURE" "$backup_dir/fixture.keiro"
perl -0pi -e 's/(    outcome no-op ReservationNoOp\.DuplicateRequest\n)/$1    write lastRequestId := cmd.requestId\n/' "$backup_dir/fixture.keiro"
expect_check_red "write from a no-op" "DomainOutcomeSilentWrites"

restore_event_stream
run_conformance >/dev/null
git diff --check
echo "PASS: typed domain outcome mutations were caught and exact files restored"
