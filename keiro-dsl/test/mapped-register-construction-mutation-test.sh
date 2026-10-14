#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fixture="keiro-dsl/test/fixtures/mapped-register-construction.keiro"
transducer="keiro-dsl/test/conformance-mapped-register-construction/Generated/MappedRegisterConstruction/Lifecycle/Transducer.hs"
lift="keiro-dsl/test/conformance-mapped-register-construction/Conformance/MappedRegisterConstruction/Lift.hs"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-mapped-register-mutation.XXXXXX")"
case "$backup_dir" in *keiro-mapped-register-mutation.*) ;; *) exit 1 ;; esac
cp "$fixture" "$backup_dir/fixture"
cp "$transducer" "$backup_dir/transducer"
cp "$lift" "$backup_dir/lift"
restore() {
  cp "$backup_dir/fixture" "$fixture"
  cp "$backup_dir/transducer" "$transducer"
  cp "$backup_dir/lift" "$lift"
}
cleanup() {
  restore
  rm -f "$backup_dir/fixture" "$backup_dir/transducer" "$backup_dir/lift" "$backup_dir/red.log"
  rmdir "$backup_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
baseline_digest="$(shasum -a 256 "$fixture" "$transducer" "$lift")"

run_green() {
  cabal test -v0 keiro-dsl-conformance-mapped-register-construction --test-show-details=direct
}
run_check() {
  cabal run -v0 keiro-dsl -- check "$fixture"
}
expect_red() {
  local label="$1" expected="$2"
  shift 2
  set +e
  "$@" >"$backup_dir/red.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]] || ! rg -F "$expected" "$backup_dir/red.log" >/dev/null; then
    cat "$backup_dir/red.log"
    echo "FAIL: mutation did not fail its named gate: $label ($expected)"
    exit 1
  fi
  echo "PASS: mutation fails its named gate: $label"
  restore
}
mutate() {
  python3 - "$1" "$fixture" "$transducer" "$lift" <<'PY'
import pathlib, re, sys
mode, fixture, transducer, lift = sys.argv[1:]
p = pathlib.Path(lift if mode == 'body' else fixture if mode in ['projection', 'arithmetic-projection', 'ownership'] else transducer)
s = p.read_text()
if mode == 'body':
    s = s.replace('atTime value = MaybeTime (Just value)', 'atTime _value = MaybeTime Nothing')
elif mode == 'identity':
    s, count = re.subn(r'lifecycleFoldFingerprint = "[0-9a-f]{32}"', 'lifecycleFoldFingerprint = "omitted-lift-provenance"', s)
    assert count == 1
elif mode == 'recovery':
    s = s.replace('{ markedAt = d.markedAt', '{ markedAt = K.opaqueLit (read "1970-01-01 00:00:00 UTC")', 1)
elif mode == 'guard':
    s = s.replace('        B.requireGuard $\n          B.reg @"automatic" .== K.lit True\n', '', 1)
elif mode == 'slot':
    s = s.replace('K.TApp1 Lift.atTime (d.markedAt)', 'K.opaqueLit Bindings.noTime', 1)
elif mode == 'output':
    s = s.replace('{ markedAt = d.markedAt', '{ markedAt = K.TApp1 id (d.markedAt)', 1)
elif mode == 'ownership':
    s = s.replace('write dormantSince := mapped(cmd.markedAt)', 'implementation hole\n    write dormantSince := mapped(cmd.markedAt)', 1)
else:
    declaration = '''mapped structural record ScalarCarrier {
  haskell package=keiro-dsl module=Conformance.MappedRegisterConstruction.Domain type=ScalarCarrier
  binding = "Conformance.MappedRegisterConstruction.Bindings.scalarBinding"
  binding-version = "1"
  canonical-type = "conformance.ScalarCarrier.v1"
  fixtures = "Conformance.MappedRegisterConstruction.Bindings.scalarCases"
  initial = "Conformance.MappedRegisterConstruction.Bindings.scalarInitial"
  wire object constructor=ScalarCarrier unknown-fields=reject {
    observed as "observed" : Time required
    count as "count" : Integer required
  }
}

'''
    s = s.replace('aggregate Lifecycle', declaration + 'aggregate Lifecycle')
    s = s.replace('    automatic Bool = False', '    automatic Bool = False\n    carrier ScalarCarrier = initial')
    if mode == 'projection':
        s = s.replace('mapped(cmd.markedAt)', 'mapped(reg.carrier.observed)')
    else:
        s = s.replace('write-lift from Time', 'write-lift from Integer')
        s = s.replace('mapped(cmd.markedAt)', 'mapped(reg.carrier.count + 1)')
assert s != p.read_text(), mode
p.write_text(s)
PY
}

run_green
mutate body
expect_red "lift contradicts declared cases" "FAIL  structural/write-lift case: MaybeTime/epoch" run_green
mutate identity
expect_red "lift provenance omitted from generated identity" "FAIL  lift version participates in fold and snapshot identity" run_green
mutate recovery
expect_red "head event no longer recovers the command" "FAIL  validateTransducer is empty" run_green
mutate guard
expect_red "generated sibling guard bypassed" "FAIL  complementary guard verification remains disjoint" run_green
mutate slot
expect_red "generated mapped slot bypassed" "FAIL  generated mapped lift writes the command timestamp" run_green
mutate output
expect_red "lift moved into event output" "FAIL  mapped lift occurs only inside declared register slots" run_green
mutate projection
expect_red "mapped projection wrapped inside a lift" "AggregateExpressionMappedLiftProjectionUnsupported" run_check
mutate arithmetic-projection
expect_red "projection hidden under arithmetic" "AggregateExpressionMappedLiftProjectionUnsupported" run_check
mutate ownership
expect_red "Hole combined with a declared write" "AggregateTransitionOwnershipConflict" run_check
[[ "$(shasum -a 256 "$fixture" "$transducer" "$lift")" == "$baseline_digest" ]]
run_green
cabal test -v0 keiro-dsl-test --test-options='--match "mapped register construction"' --test-show-details=direct
