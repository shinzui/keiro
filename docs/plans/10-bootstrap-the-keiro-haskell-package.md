---
id: 10
slug: bootstrap-the-keiro-haskell-package
title: "Bootstrap the keiro Haskell package"
kind: exec-plan
created_at: 2026-05-15T15:00:09Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
master_plan: "docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md"
---

# Bootstrap the keiro Haskell package

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro currently contains research documents, Haskell spikes, a docs website, and Nix/dev tooling, but no production Haskell package. This plan creates the compiling library scaffold that all later implementation plans extend. After completion, a contributor can run `cabal build all` and `cabal test all` from the repository root and see a minimal `Keiro` module compile under the same dependency stack that will support the command cycle.

The visible behavior is intentionally modest: the repository changes from "research-only" to "importable package." The package exposes a tiny placeholder module and one smoke test, while its Cabal file, local dependency references, and development commands are ready for EP-11 through EP-15.


## Progress

- [x] M1 — Create the Cabal package, source tree, test tree, `Keiro.Prelude`, and `cabal.project` without implementing the event-sourcing API yet. Completed 2026-05-15.
- [x] M2 — Wire dependency bounds and local package references for kiroku, keiki, keiki-codec-json, shibuya, hasql, effectful, streamly, aeson, aeson-casing, text, uuid, time, `generic-lens`, `lens`, and test libraries. Completed 2026-05-15.
- [x] M3 — Add `Justfile` commands for Haskell build/test and verify they coexist with the existing docs website commands. Completed 2026-05-15.
- [x] M4 — Build and test the empty library, then update `README.md` status text from "no Haskell source yet" to "library scaffold exists; v1 API under implementation." Completed 2026-05-15.


## Surprises & Discoveries

- Discovery: The local `keiki` packages declared `time ^>=1.12`, while the GHC 9.12 environment provides `time-1.14`.
  Evidence: `cabal build all` rejected `keiki-0.1.0.0` with `conflict: time==1.14/installed-656e, keiki => time^>=1.12`.
  Response: The sibling `keiki.cabal`, `keiki-codec-json.cabal`, and `jitsurei.cabal` bounds were updated to `time ^>=1.14`, and keiro does not carry an `allow-newer` override.

- Discovery: The Hackage `aeson-casing-0.2.0.0` API exports `aesonDrop`, `aesonPrefix`, `snakeCase`, `trainCase`, `camelCase`, and `pascalCase`, not `camelTo2`.
  Evidence: `cabal build all` failed with `Module 'Data.Aeson.Casing' does not export 'camelTo2'`.
  Response: `Keiro.Prelude` re-exports the actual Hackage casing helpers.

- Discovery: `cabal test all` includes local dependency package test suites because unreleased sibling packages are listed in `cabal.project`, and keiki's symbolic tests require the external `z3` executable.
  Evidence: `cabal test all` reached `keiki-test` and failed with `Unable to locate executable for Z3`; `which z3` returned `z3 not found`.
  Response: `flake.nix` now includes `pkgs.z3` in the development shell. The keiro scaffold itself is validated with `cabal test keiro-test`.


## Decision Log

- Decision: Bootstrap only the package skeleton and smoke tests in this plan.
  Rationale: The later plans need a stable build surface, but mixing API design into the scaffold plan would make the first commit harder to review and would create avoidable conflicts with EP-11.
  Date: 2026-05-15.

- Decision: Use local `source-repository-package` or `packages:` entries for sibling repositories during early implementation when Hackage versions are unavailable.
  Rationale: The user is actively landing keiki and kiroku changes in parallel. The plan should let keiro compile against local checked-out dependencies while preserving a clear path to Hackage bounds before release.
  Date: 2026-05-15.

- Decision: Prefer Hackage packages in `cabal.project` and keep local `packages:` entries only for unreleased sibling libraries.
  Rationale: The root project initially listed local Hasql and Shibuya paths, but those packages are available from Hackage. Using Hackage by default reduces accidental coupling to local checkouts while still allowing keiro to consume unreleased `keiki`, `keiki-codec-json`, and `kiroku-store`.
  Date: 2026-05-15.


## Outcomes & Retrospective

Completed 2026-05-15. Keiro now has a compiling Haskell package scaffold with `keiro.cabal`, `cabal.project`, `src/Keiro.hs`, `src/Keiro/Prelude.hs`, and `test/Main.hs`. The package exposes only `Keiro.version` and the custom prelude; it deliberately does not define `runCommand`, `EventStream`, snapshots, read models, process managers, or durable timers. The Justfile now has `haskell-build`, `haskell-test`, and `haskell-verify`, and `README.md` describes the repository as implementation-starting rather than research-only.

Validation passed with `cabal build all`, `cabal test keiro-test`, `just --list`, `just haskell-verify`, and `nix develop -c cabal test all`. The full Nix-shell test run passed all local dependency suites as well: `keiki-test`, `keiki-codec-json-test`, `kiroku-store-test`, and `keiro-test`. Adding `pkgs.z3` to the dev shell was necessary because keiki's symbolic tests require the Z3 executable.


## Context and Orientation

Repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. After this plan, the root has `keiro.cabal`, `cabal.project`, `src/Keiro.hs`, `src/Keiro/Prelude.hs`, and `test/Main.hs`. `flake.nix` provides GHC 9.12, `cabal-install`, PostgreSQL 18, `just`, Node, pnpm, process-compose, and Z3 in the dev shell. `Justfile` has both website tasks and Haskell tasks.

The dependency registry identifies this repository as `shinzui/keiro`, a Haskell framework with dependencies on `shinzui/kiroku`, `shinzui/keiki`, `shinzui/shibuya`, `hasql/hasql`, and `effectful/effectful`. The dependency source paths discovered through `mori` are:

- `shinzui/kiroku`: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, package `kiroku-store`, plus `shibuya-kiroku-adapter`.
- `shinzui/keiki`: `/Users/shinzui/Keikaku/bokuno/keiki`, packages `keiki`, `keiki-codec-json`, and `keiki-codec-json-test`.
- `shinzui/shibuya`: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, package `shibuya-core`.
- `hasql/hasql`: `/Users/shinzui/Keikaku/hub/haskell/hasql-project`, packages `hasql`, `hasql-pool`, and `hasql-transaction`.
- `effectful/effectful`: `/Users/shinzui/Keikaku/hub/haskell/effectful-project`, packages `effectful-core`, `effectful`, and `effectful-th`.

Do not search `/nix/store`. If dependency APIs are unclear, use `mori registry show <project> --full`, `mori registry docs <project>`, and read the source paths above.


## Plan of Work

Milestone 1 creates the minimum package shape. Add `keiro.cabal` at the repository root with one library named `keiro`, `hs-source-dirs: src`, public `Keiro` and `Keiro.Prelude` modules, strict warnings, `GHC2024`, and the local extensions from `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md` and `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md`: `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, and `PackageImports`. Create `src/Keiro.hs` with a small exported value such as `version :: Text` or a placeholder module header; do not expose future API names yet. Create `test/Main.hs` with a smoke assertion that imports `Keiro`.

Milestone 2 wires dependencies and the local prelude. The root `cabal.project` includes `.` plus local package paths only for unreleased sibling libraries: `keiki`, `keiki-codec-json`, and `kiroku-store`. Hackage packages such as `shibuya-core`, `hasql`, `hasql-pool`, `hasql-transaction`, and `effectful` are resolved from Hackage. The first library dependency set includes only what the rest of the MasterPlan will use: `aeson`, `aeson-casing`, `base`, `effectful`, `generic-lens`, `hasql`, `hasql-pool`, `hasql-transaction`, `keiki`, `keiki-codec-json`, `kiroku-store`, `lens`, `shibuya-core`, `streamly`, `text`, `time`, `uuid`, and `vector`. `src/Keiro/Prelude.hs` follows the custom-prelude pattern: the module header exports `module X` and `module Control.Lens`; imports use package-qualified imports such as `import "base" GHC.Generics as X (Generic)`; the module imports `import "generic-lens" Data.Generics.Labels ()`; it re-exports `Control.Lens`; and it re-exports common types/functions such as `Text`, `UTCTime`, `Proxy`, `Generic`, `MonadIO`, `liftIO`, Aeson JSON classes/options, and the Hackage `aeson-casing` helpers. Keep domain types and large utilities out of the prelude.

Milestone 3 updates developer commands. Add `haskell-build`, `haskell-test`, and `haskell-verify` targets to `Justfile`; preserve existing website targets. The verification target should run `cabal build all`, `cabal test all`, and the existing website verification if that remains cheap enough. If website verification is too slow or requires installed Node dependencies, keep it as a separate `website-verify` target and document the split in `README.md`.

Milestone 4 updates documentation and checks. Change the `README.md` status section so it no longer says there is no Haskell source. It should state that the package scaffold exists and point implementers to this MasterPlan and child plans. Then run the validation commands.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/keiro`, inspect dependency package names before editing:

```bash
mori show --full
mori registry show shinzui/kiroku --full
mori registry show shinzui/keiki --full
mori registry show shinzui/shibuya --full
```

Create the package files and run:

```bash
cabal build all
nix develop -c cabal test all
just haskell-verify
```

The expected successful transcript should include lines equivalent to:

```text
Build profile: -w ghc-9.12.x
Build targets: all
Test suite keiro-test: PASS
```

If Cabal cannot find local sibling packages, update `cabal.project` with explicit `packages:` entries pointing at unreleased dependency package directories listed in Context and Orientation, then rerun `cabal build all`. Prefer Hackage for dependencies that are available there.


## Validation and Acceptance

Acceptance requires the repository to have `keiro.cabal`, `cabal.project`, `src/Keiro.hs`, and `test/Main.hs`; `cabal build all` and `nix develop -c cabal test all` must pass from the repository root; and `just --list` must show the new Haskell commands without losing the existing website commands.

Acceptance also requires `src/Keiro/Prelude.hs` to be exposed by the library and imported by the smoke-test or a small test module. The scaffold must not implement `runCommand`, `EventStream`, snapshots, read models, or process managers. Those names belong to later plans, and keeping them out of EP-10 proves the bootstrap is only infrastructure.


## Idempotence and Recovery

Creating the package files is additive. If the first `cabal build all` fails because a local dependency is missing from `cabal.project`, add only the missing package path and rerun. If dependency version bounds are too tight for the local sibling repositories, loosen bounds in `keiro.cabal` during development and record the exact observed version in Surprises & Discoveries. Do not remove the existing docs website files or generated `site-dist/`.


## Interfaces and Dependencies

This plan owns only the build and style interface:

```text
keiro.cabal
cabal.project
src/Keiro.hs
src/Keiro/Prelude.hs
test/Main.hs
Justfile targets: haskell-build, haskell-test, haskell-verify
```

All future public API modules are intentionally deferred. The package must be ready for EP-11 to add `Keiro.Stream`, `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Snapshot.Policy`, and related exports without restructuring the build. Any Haskell records added by later plans must import `Keiro.Prelude` and use no field prefixes, strict fields, explicit deriving strategies, and `#field` lens access/update as described in the jitsurei record-pattern guide.
