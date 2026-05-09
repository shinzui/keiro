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
