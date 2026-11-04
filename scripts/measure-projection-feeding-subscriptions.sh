#!/usr/bin/env bash
# Same harness sources, separately linked against each package set. Keep runs serial.
set -euo pipefail
[[ $# == 3 ]] || { echo 'usage: measure-projection-feeding-subscriptions.sh BASELINE CANDIDATE OUTPUT' >&2; exit 2; }
baseline=$1
candidate=$2
output=$3
[[ -x "$baseline" && -x "$candidate" ]] || exit 2
[[ -z "${KEIRO_INSPECTION_RETENTION_SECONDS:-}" ]] || { echo "run retention separately" >&2; exit 2; }
mkdir "$output"
for pair in 1 2 3 4 5; do
  if ((pair % 2)); then controls=(control-a control-b); else controls=(control-b control-a); fi
  for label in "${controls[@]}"; do
    KEIRO_INSPECTION_SECONDS=20 "$baseline" "$output/$label/$pair" 100 1 projection-idle +RTS -N2 -T -RTS > "$output/$label-$pair.log" 2>&1
  done
  for mode in projection-idle projection-poll projection-feed; do
    if ((pair % 2)); then order=(baseline candidate); else order=(candidate baseline); fi
    for side in "${order[@]}"; do
      binary=$baseline
      expect_names=0
      if [[ $side == candidate ]]; then binary=$candidate; expect_names=1; fi
      KEIRO_PROJECTION_EXPECT_SUBSCRIPTIONS=$expect_names KEIRO_INSPECTION_SECONDS=20 \
        "$binary" "$output/$side/$pair/$mode" 100 1 "$mode" +RTS -N2 -T -RTS \
        > "$output/$side-$pair-$mode.log" 2>&1
    done
  done
done
python3 scripts/analyze-projection-feeding-subscriptions.py "$output"
