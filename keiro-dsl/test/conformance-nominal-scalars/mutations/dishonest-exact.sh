#!/usr/bin/env bash
set -euo pipefail

KEIRO_NOMINAL_MUTATION=dishonest-exact cabal test keiro-dsl-conformance-nominal-scalars
