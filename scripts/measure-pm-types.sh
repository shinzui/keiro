#!/usr/bin/env bash
# Execute binaries returned by cabal list-bin; never inspect their directories.
set -euo pipefail
if [ "$#" -ne 4 ]; then
  echo 'usage: measure-pm-types.sh BASELINE_BINARY CANDIDATE_BINARY OUTPUT_DIRECTORY OPS_PER_SECOND' >&2
  exit 2
fi
baseline=$1
candidate=$2
output=$3
rate=$4
[[ -x "$baseline" && -x "$candidate" ]] || { echo 'both binaries must be executable' >&2; exit 2; }
[[ "$rate" =~ ^[1-9][0-9]*$ && "$rate" -le 1000 ]] || { echo 'rate must be 1..1000' >&2; exit 2; }
seconds=${KEIRO_INSPECTION_SECONDS:-20}
[[ "$seconds" =~ ^[1-9][0-9]*$ && "$seconds" -ge 20 ]] || { echo 'at least 20 seconds per trial required' >&2; exit 2; }
[[ -z "${KEIRO_INSPECTION_RETENTION_SECONDS:-}" ]] || { echo 'run retention separately from latency measurements' >&2; exit 2; }
pairs=${PM_TYPES_PAIRS:-5}
[[ "$pairs" =~ ^[1-9][0-9]*$ && "$pairs" -ge 5 ]] || { echo 'at least five pairs required' >&2; exit 2; }
mkdir "$output"
output=$(cd "$output" && pwd)
{
  date -u +%FT%TZ
  echo 'candidate source:'
  git rev-parse HEAD
  git diff --binary
  echo 'baseline source:'
  git -C "${PM_TYPES_BASELINE_CHECKOUT:-../keiro-pm-types-baseline}" rev-parse HEAD
  git -C "${PM_TYPES_BASELINE_CHECKOUT:-../keiro-pm-types-baseline}" diff --exit-code
  uname -a
  ghc --version
  postgres --version
  shasum -a 256 "$baseline" "$candidate"
  echo "rate=$rate pairs=$pairs seconds=$seconds RTS=-N2,-T"
} > "$output/identity.txt"
run() {
  local binary=$1 label=$2 mode=$3 load=$4 pair=$5
  "$binary" "$output/$label/$pair" "$load" 1 "$mode" +RTS -N2 -T -RTS > "$output/$label-$pair.log" 2>&1
}
for ((pair=1; pair<=pairs; pair++)); do
  # Alternate the order within every comparison. Same-source idle repeats
  # characterize noise independently of a code change or newly successful route.
  if ((pair % 2)); then
    run "$baseline" baseline-disabled disabled "$rate" "$pair"
    run "$candidate" candidate-disabled disabled "$rate" "$pair"
    run "$baseline" baseline-capacity disabled saturation "$pair"
    run "$candidate" candidate-capacity disabled saturation "$pair"
    run "$baseline" baseline-idle idle "$rate" "$pair"
    run "$candidate" candidate-idle idle "$rate" "$pair"
    run "$baseline" control-a idle "$rate" "$pair"
    run "$baseline" control-b idle "$rate" "$pair"
    run "$candidate" catalog-idle pm-types-idle "$rate" "$pair"
    run "$candidate" catalog-active pm-types "$rate" "$pair"
    run "$candidate" many-idle pm-types-many-idle "$rate" "$pair"
    run "$candidate" many-active pm-types-many "$rate" "$pair"
  else
    run "$candidate" candidate-disabled disabled "$rate" "$pair"
    run "$baseline" baseline-disabled disabled "$rate" "$pair"
    run "$candidate" candidate-capacity disabled saturation "$pair"
    run "$baseline" baseline-capacity disabled saturation "$pair"
    run "$candidate" candidate-idle idle "$rate" "$pair"
    run "$baseline" baseline-idle idle "$rate" "$pair"
    run "$baseline" control-b idle "$rate" "$pair"
    run "$baseline" control-a idle "$rate" "$pair"
    run "$candidate" catalog-active pm-types "$rate" "$pair"
    run "$candidate" catalog-idle pm-types-idle "$rate" "$pair"
    run "$candidate" many-active pm-types-many "$rate" "$pair"
    run "$candidate" many-idle pm-types-many-idle "$rate" "$pair"
  fi
done
python3 "$(dirname "$0")/analyze-pm-types.py" "$output" "$pairs"
