#!/usr/bin/env bash
# Opt-in entry-count probe for generated process-reaction managers.
set -euo pipefail

TMP_ROOT="$(mktemp -d)"
REACTION_LOG="$TMP_ROOT/reactions.log"
STATE_LOG="$TMP_ROOT/state-authority.log"
DEFAULT_LOG="$TMP_ROOT/default.log"
BUILD_DIR="$TMP_ROOT/dist-probe"
trap 'rm -rf "$TMP_ROOT"' EXIT

run_probe() {
  local target="$1"
  local log="$2"
  if ! cabal test \
    --builddir="$BUILD_DIR" \
    "$target" \
    --constraint='keiro +reaction-hydration-probe' \
    --test-options='--hydration-probe' \
    --test-show-details=direct >"$log" 2>&1; then
    cat "$log"
    exit 1
  fi
}

case_count() {
  local log="$1"
  local case_name="$2"
  local operation="$3"
  local stream_fragment="$4"
  awk -v case_name="$case_name" -v operation="$operation" -v stream_fragment="$stream_fragment" '
    index($0, "reaction-case-start " case_name) { inside = 1; next }
    index($0, "reaction-case-end " case_name) { inside = 0 }
    inside && index($0, "\"marker\":\"reaction-probe\"") && (operation == "" || index($0, "\"operation\":\"" operation "\"")) && index($0, stream_fragment) { count += 1 }
    END { print count + 0 }
  ' "$log"
}

assert_count() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label expected=$expected actual=$actual"
    exit 1
  fi
  echo "$label=$actual"
}

assert_at_least() {
  local label="$1"
  local minimum="$2"
  local actual="$3"
  if (( actual < minimum )); then
    echo "FAIL: $label minimum=$minimum actual=$actual"
    exit 1
  fi
  echo "$label=$actual (minimum=$minimum)"
}

run_probe keiro-dsl:keiro-dsl-conformance-process-reactions "$REACTION_LOG"

for shape in same distinct; do
  for count in 8 32 128; do
    first="fanout-$count-$shape-first-delivery"
    replay="fanout-$count-$shape-accepted-redelivery"
    coordinate="fan-out=$count shape=$shape"

    assert_count "$coordinate first saga hydrate entries" 1 "$(case_count "$REACTION_LOG" "$first" hydrate '"stream":"scalingSaga-')"
    assert_count "$coordinate first saga witness entries" 0 "$(case_count "$REACTION_LOG" "$first" witness '"stream":"scalingSaga-')"
    assert_count "$coordinate first target hydrate entries" "$count" "$(case_count "$REACTION_LOG" "$first" hydrate '"stream":"incident-')"
    assert_count "$coordinate first total probe entries" "$((count + 1))" "$(case_count "$REACTION_LOG" "$first" '' '')"

    assert_count "$coordinate replay saga hydrate entries" 0 "$(case_count "$REACTION_LOG" "$replay" hydrate '"stream":"scalingSaga-')"
    assert_count "$coordinate replay saga witness entries" 1 "$(case_count "$REACTION_LOG" "$replay" witness '"stream":"scalingSaga-')"
    assert_count "$coordinate replay target entries" 0 "$(case_count "$REACTION_LOG" "$replay" '' '"stream":"incident-')"
    assert_count "$coordinate replay total probe entries" 1 "$(case_count "$REACTION_LOG" "$replay" '' '')"
  done
done
assert_count "no-advance probe entries" 0 "$(case_count "$REACTION_LOG" no-advance '' '')"
assert_count "no-advance timer-phase entries" 0 "$(case_count "$REACTION_LOG" no-advance timer-phase '')"

run_probe keiro-dsl:keiro-dsl-conformance-process-state-authority "$STATE_LOG"
conflict_hydrates="$(case_count "$STATE_LOG" state-authority-forced-conflict hydrate '"stream":"escalation-inc_01h455vb4pex5vsknk084sn07w"')"
assert_at_least "state-authority forced-conflict saga hydrate entries" 33 "$conflict_hydrates"
assert_count "state-authority forced-conflict saga witness entries" 0 "$(case_count "$STATE_LOG" state-authority-forced-conflict witness '"stream":"escalation-inc_01h455vb4pex5vsknk084sn07w"')"
assert_count "state-authority forced-conflict total probe entries" "$conflict_hydrates" "$(case_count "$STATE_LOG" state-authority-forced-conflict '' '')"

cabal test keiro-dsl:keiro-dsl-conformance-process-reactions --test-show-details=direct >"$DEFAULT_LOG" 2>&1
if grep -F '"marker":"reaction-probe"' "$DEFAULT_LOG" >/dev/null; then
  echo "FAIL: the ordinary build emitted opt-in reaction probe markers"
  exit 1
fi

echo "PASS: reaction hydration and witness entry counts are explicit; the default build is silent"
