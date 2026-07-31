#!/usr/bin/env bash
set -euo pipefail

cabal exec ghc -- -fno-code keiro-dsl/test/conformance-nominal-scalars/compile-fail/PartialInverse.hs
