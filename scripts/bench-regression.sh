#!/usr/bin/env bash
# Run all fixed-workload guards, retaining failures for every family. CSV families
# compare with immutable recording source measured on this machine; producer
# identity retains its same-process paired ceiling. See keiro/bench/REGRESSION.md.
#
# Usage: scripts/bench-regression.sh [guard...]
# With no arguments every guard runs. Guard names: producer-identity, outbox,
# inbox, command, projection, read-model.
set -uo pipefail

cd "$(dirname "$0")/.."

if [ "${KEIRO_BENCH_LOCKED:-}" != 1 ]; then
  exec python3 scripts/release_workflow.py locked -- env KEIRO_BENCH_LOCKED=1 scripts/bench-regression.sh "$@"
fi

run_guard() {
  local name="$1"
  shift
  echo "##### guard ${name} $(date -u +%FT%TZ)"
  "$@"
  local status=$?
  results+=("${name}=${status}")
  if [ "$status" -eq 2 ]; then
    inconclusive=1
  elif [ "$status" -ne 0 ]; then
    failed=1
  fi
}

declare -a results=()
failed=0
inconclusive=0

wanted=("$@")
if [ "${#wanted[@]}" -eq 0 ]; then
  wanted=(producer-identity outbox inbox command projection read-model)
fi

for guard in "${wanted[@]}"; do
  case "$guard" in
    producer-identity)
      run_guard producer-identity cabal bench keiro-bench --benchmark-options="-p producer-identity -j1 --time-mode wall --hide-progress --stdev 1 --timeout 120s +RTS -N2 -RTS"
      ;;
    outbox|inbox|command|projection|read-model)
      if [ "$guard" = projection ]; then
        KEIRO_READ_MODEL_P95=1 run_guard "$guard" python3 scripts/bench_guard.py "$guard"
      else
        run_guard "$guard" python3 scripts/bench_guard.py "$guard"
      fi
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
if [ "$inconclusive" -ne 0 ]; then
  echo "BENCH_REGRESSION=INCONCLUSIVE"
  exit 2
fi
echo "BENCH_REGRESSION=PASSED"
