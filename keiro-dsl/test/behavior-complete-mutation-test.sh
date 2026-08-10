#!/usr/bin/env bash
# Falsification evidence for ExecPlans 159 and 191's complete behavior contract.
set -euo pipefail

WITNESSES="keiro-dsl/test/conformance-behavior-complete/BehaviorComplete/Journey/BehaviorHoles.hs"
LEGACY_HOLES="keiro-dsl/test/conformance-behavior-complete/BehaviorComplete/Journey/Holes.hs"
TRANSDUCER="keiro-dsl/test/conformance-behavior-complete/Generated/BehaviorComplete/Journey/Transducer.hs"
CODEC="keiro-dsl/test/conformance-behavior-complete/Generated/BehaviorComplete/Journey/Codec.hs"
SCAFFOLD_SOURCE="keiro-dsl/src/Keiro/Dsl/Scaffold.hs"
SPEC="keiro-dsl/test/fixtures/behavior-complete.keiro"
OUT="keiro-dsl/test/conformance-behavior-complete"
LEDGER="$OUT/keiro-dsl-ledger.context.behavior-complete.txt"

BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keiro-behavior-mutation.XXXXXX")"
case "$BACKUP_DIR" in
  *keiro-behavior-mutation.*) ;;
  *) echo "FAIL: unexpected backup path: $BACKUP_DIR"; exit 1 ;;
esac

cp "$WITNESSES" "$BACKUP_DIR/BehaviorHoles.hs"
cp "$LEGACY_HOLES" "$BACKUP_DIR/Holes.hs"
cp "$TRANSDUCER" "$BACKUP_DIR/Transducer.hs"
cp "$CODEC" "$BACKUP_DIR/Codec.hs"
cp "$SCAFFOLD_SOURCE" "$BACKUP_DIR/Scaffold.hs"
cp "$LEDGER" "$BACKUP_DIR/ledger.txt"

restore_all() {
  cp "$BACKUP_DIR/BehaviorHoles.hs" "$WITNESSES"
  cp "$BACKUP_DIR/Holes.hs" "$LEGACY_HOLES"
  cp "$BACKUP_DIR/Transducer.hs" "$TRANSDUCER"
  cp "$BACKUP_DIR/Codec.hs" "$CODEC"
  cp "$BACKUP_DIR/Scaffold.hs" "$SCAFFOLD_SOURCE"
  cp "$BACKUP_DIR/ledger.txt" "$LEDGER"
}

cleanup() {
  restore_all
  rm -f "$BACKUP_DIR/BehaviorHoles.hs" "$BACKUP_DIR/Holes.hs" "$BACKUP_DIR/Transducer.hs" "$BACKUP_DIR/Codec.hs" "$BACKUP_DIR/Scaffold.hs" "$BACKUP_DIR/ledger.txt" "$BACKUP_DIR/mutation.log"
  rmdir "$BACKUP_DIR"
}
trap cleanup EXIT

restore_file() {
  cp "$BACKUP_DIR/$1" "$2"
}

run_report() {
  cabal run -v0 keiro-dsl-behavior-complete-report -- --format=json
}

expect_red() {
  local label="$1"
  local expected="$2"
  local require_location="${3:-yes}"
  set +e
  run_report >"$BACKUP_DIR/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    sed -n '1,240p' "$BACKUP_DIR/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  if ! grep -Fq "$expected" "$BACKUP_DIR/mutation.log"; then
    sed -n '1,240p' "$BACKUP_DIR/mutation.log"
    echo "FAIL: $label failed through an unexpected gate (wanted $expected)"
    exit 1
  fi
  if [[ "$require_location" == "yes" ]] && ! grep -Eq 'keiro-dsl/test/fixtures/behavior-complete\.keiro:[0-9]+:[0-9]+' "$BACKUP_DIR/mutation.log"; then
    sed -n '1,240p' "$BACKUP_DIR/mutation.log"
    echo "FAIL: $label did not report the current exact source position"
    exit 1
  fi
  echo "ok: $label -> $expected"
}

expect_focused_test_red() {
  local label="$1"
  set +e
  cabal test -v0 keiro-dsl-test --test-options='--match "generates direct fields(Command) output and separate create-once pending witnesses"' >"$BACKUP_DIR/mutation.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    sed -n '1,240p' "$BACKUP_DIR/mutation.log"
    echo "FAIL: mutation stayed green: $label"
    exit 1
  fi
  echo "ok: $label -> focused generated-source assertion"
}

echo "== baseline: all 19 obligations are filled and green =="
run_report >/dev/null

echo "== obsolete legacy hook is reported and cannot affect execution =="
SCAFFOLD_OUTPUT="$(cabal run -v0 keiro-dsl -- scaffold "$SPEC" --out "$OUT" 2>&1)"
grep -Fq "Journey.Holes.transition1EmptyStartOutput1Started" <<<"$SCAFFOLD_OUTPUT"
sed -i.sed-bak 's/requestId = d.requestId/requestId = error "obsolete identity hook executed"/' "$LEGACY_HOLES"
rm -f "$LEGACY_HOLES.sed-bak"
run_report >/dev/null
restore_file Holes.hs "$LEGACY_HOLES"

sed -i.sed-bak '/behavior-v1-43b8fc7fa48595dd/d' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "remove a later-state witness" '"missing":["behavior-v1-43b8fc7fa48595dd"]' no
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak 's/activeHistory = \[startedEvent 0\]/activeHistory = []/' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "use a history reaching the wrong source" 'history-wrong-source'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak 's/behavior-v1-2f3ebf37a55781db/behavior-v1-swap-placeholder/; s/behavior-v1-db1a553baa3eda84/behavior-v1-2f3ebf37a55781db/; s/behavior-v1-swap-placeholder/behavior-v1-db1a553baa3eda84/' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "swap same-target guarded sibling keys" 'edge-attribution'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak '/behavior-v1-83b0a46823e1a788/ s/(Rejects RejectNoMatchingEdge)/NoOp/' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "change rejection to no-op" 'expectation-kind'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak '/behavior-v1-43b8fc7fa48595dd/ s/(startCommand 0)/(decideCommand 0)/' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "use another rejecting command for a required cell" 'command-mismatch'
restore_file BehaviorHoles.hs "$WITNESSES"

perl -0pi -e 's/(B\.onCmd inCtorPing \$ \\_d -> B\.do\n)/$1        B.slot \@"lastAmount" =: K.lit 1\n/' "$TRANSDUCER"
expect_red "change a no-op register" 'noop-register-change'
restore_file Transducer.hs "$TRANSDUCER"

sed -i.sed-bak '/behavior-v1-db1a553baa3eda84/d' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "omit one guard alternative" '"missing":["behavior-v1-db1a553baa3eda84"]' no
restore_file BehaviorHoles.hs "$WITNESSES"

perl -0pi -e 's/ReplayWitness \(key "behavior-v1-f0fbe3a3ba0b40e8"\) activeHistory \[retiredEvent 0, retirementAuditedEvent 0\]/live "behavior-v1-f0fbe3a3ba0b40e8" activeHistory (retireCommand 0) (Emits (retiredEvent 0 :| [retirementAuditedEvent 0]))/' "$WITNESSES"
expect_red "expect a replay-only edge to fire forward" 'witness-kind'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak '/behavior-v1-f0fbe3a3ba0b40e8/ s/retiredEvent 0, retirementAuditedEvent 0/retiredEvent 1, retirementAuditedEvent 1/' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "let the live twin steal a replay witness" 'replay-edge-attribution'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak '/behavior-v1-08a2bda57424a16e/ s/startedEvent 1/startedEvent 0/' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "let the live initial edge steal the initial replay witness" 'replay-edge-attribution'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak '/behavior-v1-f0fbe3a3ba0b40e8/ s/, retirementAuditedEvent 0//' "$WITNESSES"
rm -f "$WITNESSES.sed-bak"
expect_red "truncate a multi-event replay chunk" 'replay-chunk-failed'
restore_file BehaviorHoles.hs "$WITNESSES"

sed -i.sed-bak '/"Retired" ->/,/"RetirementAudited" ->/ s/<\$> o \.: "amount"/<$> ((+ 1) <$> o .: "amount")/' "$CODEC"
rm -f "$CODEC.sed-bak"
expect_red "make codec replay diverge" 'emitted-replay-failed'
restore_file Codec.hs "$CODEC"

perl -0pi -e 's/amount = d\.amount/amount = K.lit 999/' "$TRANSDUCER"
expect_red "mutate a generated identity selector" 'event-value-mismatch'
restore_file Transducer.hs "$TRANSDUCER"

perl -0pi -e 's/let edgeIndex = layoutOutgoingIndex entry/let edgeIndex = 0/' "$SCAFFOLD_SOURCE"
expect_focused_test_red "reset source-wide predicate edge indices"
restore_file Scaffold.hs "$SCAFFOLD_SOURCE"

restore_all
run_report >/dev/null
git diff --check
echo "PASS: all behavior mutations were caught and exact files restored"
