#!/usr/bin/env bash
set -euo pipefail

# This name is generated here, never supplied by a caller. Cleanup owns only
# this run's demo database; the interactive JITSUREI_DATABASE stays untouched.
keiro_verify_db="keiro_jitsurei_verify_$(date +%s)_$$_$RANDOM"
cleanup() {
  keiro_verify_status=$?
  trap - EXIT
  if ! dropdb --if-exists "$keiro_verify_db"; then
    printf 'Could not remove verification database %s\n' "$keiro_verify_db" >&2
    if [ "$keiro_verify_status" -eq 0 ]; then
      keiro_verify_status=1
    fi
  fi
  exit "$keiro_verify_status"
}
trap cleanup EXIT

printf 'Running demos in disposable database %s\n' "$keiro_verify_db"
JITSUREI_DATABASE="$keiro_verify_db" just jitsurei-all
