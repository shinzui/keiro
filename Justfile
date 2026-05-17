set shell := ["zsh", "-cu"]

site := "site-dist"

default:
    just --list

install:
    pnpm install --frozen-lockfile

website-build:
    BUNDLE_PRAGMATA_PRO=1 pnpm run build

website-dev:
    BUNDLE_PRAGMATA_PRO=1 pnpm run dev

website-preview:
    BUNDLE_PRAGMATA_PRO=1 pnpm run preview

website-linkcheck:
    node site/check-links.mjs {{site}}

website-verify: install website-build website-linkcheck

haskell-build:
    cabal build all

haskell-test:
    cabal test keiro-test
    cabal test jitsurei-test
    cabal run jitsurei:exe:jitsurei-diagrams -- --check

haskell-verify: haskell-build haskell-test website-verify
