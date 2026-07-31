#!/usr/bin/env bash
set -euo pipefail

KEIRO_NOMINAL_MUTATION=enum-transpose cabal test keiro-dsl-conformance-nominal-scalars
