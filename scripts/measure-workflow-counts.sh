#!/usr/bin/env bash
set -euo pipefail
# Run inside nix develop. All legs are serial and use identical harness settings.
exec python3 scripts/analyze-workflow-counts.py --measure "$@"
