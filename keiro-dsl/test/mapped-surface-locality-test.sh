#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

echo "== mapped surface semantic and exact-tree locality =="
cabal test -v0 keiro-dsl:keiro-dsl-test \
  --test-options='--match "mapped surface qualification"'

echo "== integrated single-service runtime conformance =="
cabal test -v0 keiro-dsl:keiro-dsl-conformance-projection-catalog

echo "== integrated workspace composition =="
cabal run -v0 keiro-dsl -- check \
  keiro-dsl/test/fixtures/projection-catalog-grown.keiro-workspace

echo "PASS: mapped surface locality is exact and invariant under unrelated workspace growth"
