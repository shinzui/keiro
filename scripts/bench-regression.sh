#!/usr/bin/env bash
# Run every benchmark regression guard and report each one, instead of stopping
# at the first failure. Each guard is one `cabal bench keiro-bench` invocation
# against a committed baseline (or, for producer-identity, a same-process
# ratio ceiling). The exit status is non-zero when any guard failed, and the
# per-guard summary is printed last so a log reader can find it without
# scrolling through tasty-bench output.
#
# Usage: scripts/bench-regression.sh [guard...]
# With no arguments every guard runs. Guard names: producer-identity, outbox,
# inbox, command, projection, read-model.
set -uo pipefail

cd "$(dirname "$0")/.."

run_guard() {
  local name="$1"
  shift
  echo "##### guard ${name} $(date -u +%FT%TZ)"
  "$@"
  local status=$?
  results+=("${name}=${status}")
  if [ "$status" -ne 0 ]; then
    failed=1
  fi
}

declare -a results=()
failed=0

wanted=("$@")
if [ "${#wanted[@]}" -eq 0 ]; then
  wanted=(producer-identity outbox inbox command projection read-model)
fi

for guard in "${wanted[@]}"; do
  case "$guard" in
    producer-identity)
      run_guard producer-identity cabal bench keiro-bench --benchmark-options="-p producer-identity -j1 --time-mode wall --hide-progress --stdev 1 --timeout 120s +RTS -N2 -RTS"
      ;;
    outbox)
      run_guard outbox cabal bench keiro-bench --benchmark-options="-p outbox -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --baseline bench/baseline-outbox.csv --fail-if-slower 25 +RTS -N2 -RTS"
      ;;
    inbox)
      run_guard inbox cabal bench keiro-bench --benchmark-options="-p inbox -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --baseline bench/baseline-inbox.csv --fail-if-slower 25 +RTS -N2 -RTS"
      ;;
    command)
      run_guard command cabal bench keiro-bench --benchmark-options="-p command -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --baseline bench/baseline-command.csv --fail-if-slower 25 +RTS -N2 -RTS"
      ;;
    projection)
      KEIRO_READ_MODEL_P95=1 run_guard projection cabal bench keiro-bench --benchmark-options="-p projection -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --baseline bench/baseline-projection.csv --fail-if-slower 25 +RTS -N2 -RTS"
      ;;
    read-model)
      run_guard read-model cabal bench keiro-bench --benchmark-options="-p read-model -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --baseline bench/baseline-read-model.csv --fail-if-slower 25 +RTS -N2 -RTS"
      ;;
    *)
      echo "unknown guard: $guard" >&2
      exit 2
      ;;
  esac
done

echo "##### guard summary $(date -u +%FT%TZ)"
for entry in "${results[@]}"; do
  echo "GUARD(${entry%%=*})=${entry#*=}"
done
if [ "$failed" -ne 0 ]; then
  echo "BENCH_REGRESSION=FAILED"
  exit 1
fi
echo "BENCH_REGRESSION=PASSED"
