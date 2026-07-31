#!/usr/bin/env bash
set -euo pipefail

KEIRO_NOMINAL_MUTATION=scalar-wire cabal test keiro-dsl-conformance-nominal-scalars
