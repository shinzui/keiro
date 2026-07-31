#!/usr/bin/env bash
set -euo pipefail

KEIRO_NOMINAL_MUTATION=id-one-direction cabal test keiro-dsl-conformance-nominal-scalars
