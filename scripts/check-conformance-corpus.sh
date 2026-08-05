#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

cabal run -v0 keiro-dsl-corpus-regen -- check
