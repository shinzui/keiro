---
id: 29
slug: introduce-keiro-core-package
title: "Introduce keiro-core package"
kind: exec-plan
created_at: 2026-05-23T15:32:15Z
intention: "intention_01ksaq6v2he24v1cczktykp4t7"
---

# Introduce keiro-core package

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is currently one Haskell package named `keiro` that contains both the stable author-facing contracts and the runtime machinery that talks to PostgreSQL, subscriptions, telemetry, and workers. This plan introduces a new sibling package named `keiro-core` so future packages can depend on the core stream, codec, event-stream, and integration-event contracts without depending on the full runtime package.

After this change, a downstream package will be able to add `keiro-core` to its `build-depends` and import modules such as `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Stream`, and `Keiro.Integration.Event`. Existing users of the `keiro` package should continue to compile unchanged because `keiro` will depend on `keiro-core` and re-export the moved modules under the same module names. The change is visible by running `cabal build keiro-core`, `cabal build all`, and the existing test suites; all should succeed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add a compilable `keiro-core` package containing the stable core modules and register it in `cabal.project` and `mori.dhall`. `mori show --full` listed both packages and `cabal build keiro-core` compiled all six moved modules. (done 2026-05-23)
- [x] M2: Update the existing `keiro` package so it depends on `keiro-core`, re-exports the moved modules, and still provides the same top-level `Keiro` facade. `cabal build keiro` succeeded and `cabal test keiro-test` passed with 81 examples. (done 2026-05-23)
- [ ] M3: Update sibling packages and documentation references where necessary, then validate `cabal build all`, `cabal test keiro-test`, `cabal test jitsurei-test`, and `cabal test keiro-migrations-test`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Cabal accepts multiple `reexported-modules` entries on following lines only when they are comma-separated. The initial field shape without commas failed while parsing `keiro.cabal`:

```text
keiro.cabal:58:25: error:
unexpected 'k'
expecting space, comma, white space or end of input
```


## Decision Log

Record every decision made while working on the plan.

- Decision: The first `keiro-core` boundary contains stable, mostly pure contract modules: `Keiro.Prelude`, `Keiro.Stream`, `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Integration.Event`, and `Keiro.Snapshot.Policy`.
  Rationale: These modules define the types and pure helpers that future packages are most likely to reuse. They do not open database transactions, run subscription workers, or depend on `effectful`, `hasql`, `shibuya`, `streamly`, or OpenTelemetry worker instrumentation. Keeping the first boundary small reduces the chance of turning `keiro-core` into a second runtime package before the future package needs are known.
  Date: 2026-05-23

- Decision: Leave `Keiro.Command`, `Keiro.Snapshot`, `Keiro.ReadModel`, `Keiro.Projection`, `Keiro.ProcessManager`, `Keiro.Router`, `Keiro.Inbox`, `Keiro.Outbox`, `Keiro.Timer`, `Keiro.Telemetry`, their schema modules, their worker modules, and their row/option types in the `keiro` package for now.
  Rationale: These modules either perform runtime work, depend on database or worker libraries, or are tightly coupled to runtime options such as OpenTelemetry tracers. Moving them now would widen `keiro-core` and make the package boundary less useful for lightweight future adapters.
  Date: 2026-05-23

- Decision: Preserve existing source-level imports by having `keiro` re-export moved modules from `keiro-core` with Cabal's `reexported-modules` field instead of renaming modules to `Keiro.Core.*`.
  Rationale: Existing examples and users import modules such as `Keiro.Codec` and `Keiro.EventStream`. Re-exporting those module names keeps that API stable while still creating a smaller dependency target for new packages.
  Date: 2026-05-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. It is a Cabal multi-package project. A Cabal package is the unit named in a `.cabal` file and listed in `cabal.project`; other packages depend on it through their `build-depends` fields.

The current root package is `keiro`, defined in `keiro.cabal`. Its library source lives under `src/`. The top-level module `src/Keiro.hs` re-exports the most common author-facing API: `Keiro.Command`, `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Router`, `Keiro.Snapshot`, and `Keiro.Stream`. The root package also exposes runtime and operational modules such as `Keiro.ReadModel`, `Keiro.Projection`, `Keiro.ProcessManager`, `Keiro.Inbox`, `Keiro.Outbox`, `Keiro.Timer`, and `Keiro.Telemetry`.

The project also contains sibling packages:

- `keiro-migrations/keiro-migrations.cabal` defines `keiro-migrations`, the package that embeds and runs SQL migrations.
- `jitsurei/jitsurei.cabal` defines `jitsurei`, the guide-backed worked examples that depend on `keiro`.
- `benchmarks/message-db-vs-kiroku/message-db-vs-kiroku.cabal` defines a benchmark package that currently does not import `keiro`.

The workspace is controlled by `cabal.project`, which currently lists `.`, `keiro-migrations`, `jitsurei`, the benchmark package, and several local dependency checkouts. This file must list the new `keiro-core` directory so Cabal can build the package from the same checkout.

The local project registry is controlled by `mori.dhall`. `mori show --full` reports this repository as `shinzui/keiro`, a Haskell framework with one package named `keiro` and declared dependencies on `shinzui/kiroku`, `shinzui/keiki`, `shinzui/shibuya`, `hasql/hasql`, and `effectful/effectful`. `mori registry search keiro-core` currently reports no matching project. The implementation must update `mori.dhall` so the registry records both packages, `keiro-core` and `keiro`.

This plan uses these terms:

`keiro-core` means the new Haskell library package that contains reusable contracts and pure helpers. It is not a new top-level namespace; it will expose existing module names such as `Keiro.Codec`.

`re-export` means the `keiro` package exposes a module that is actually implemented by `keiro-core`. Cabal supports this through a library stanza field named `reexported-modules`. A user who depends on `keiro` can still import `Keiro.Codec`, while a user who only needs the core contract can depend directly on `keiro-core` and import the same module.

`runtime module` means a module that performs effects such as database reads and writes, worker loops, telemetry spans, subscription acknowledgement, or other operational behavior. Runtime modules stay in `keiro` for this first split.


## Plan of Work

Milestone 1 creates a new package and proves it builds by itself. Create `keiro-core/keiro-core.cabal` and move the chosen core modules from `src/` into `keiro-core/src/`. The moved modules are `src/Keiro/Prelude.hs`, `src/Keiro/Stream.hs`, `src/Keiro/Codec.hs`, `src/Keiro/EventStream.hs`, `src/Keiro/Integration/Event.hs`, and `src/Keiro/Snapshot/Policy.hs`. The corresponding destination files are `keiro-core/src/Keiro/Prelude.hs`, `keiro-core/src/Keiro/Stream.hs`, `keiro-core/src/Keiro/Codec.hs`, `keiro-core/src/Keiro/EventStream.hs`, `keiro-core/src/Keiro/Integration/Event.hs`, and `keiro-core/src/Keiro/Snapshot/Policy.hs`.

The new `keiro-core/keiro-core.cabal` should mirror the root package metadata where appropriate, but its description should say that it contains stable contracts for Keiro packages. Its library stanza should expose exactly these modules:

```text
Keiro.Codec
Keiro.EventStream
Keiro.Integration.Event
Keiro.Prelude
Keiro.Snapshot.Policy
Keiro.Stream
```

Its `build-depends` should include only dependencies required by those modules: `aeson`, `aeson-casing`, `base`, `bytestring`, `generic-lens`, `keiki`, `kiroku-store`, `lens`, `scientific`, `text`, `time`, and `uuid`. Keep `default-language: GHC2024` and the same default extensions currently used by `keiro.cabal`'s `common shared` stanza: `DeriveAnyClass`, `DuplicateRecordFields`, `MultilineStrings`, `OverloadedLabels`, `OverloadedStrings`, and `PackageImports`. Do not add `effectful`, `hasql`, `shibuya-core`, `streamly`, or OpenTelemetry dependencies to `keiro-core` in this milestone.

Register the new package by adding `keiro-core` to `cabal.project` immediately after `.`. Update `mori.dhall` by adding a second package entry named `keiro-core`, typed as a Haskell library and described as "Core contracts for Keiro packages". Run `mori show --full` afterward and confirm it lists both `keiro-core` and `keiro`.

Milestone 1 is accepted when this command succeeds from the repository root:

```bash
cabal build keiro-core
```

Milestone 2 reconnects the current `keiro` package to the moved modules. Edit `keiro.cabal` so the `library` stanza depends on `keiro-core`. Remove the moved modules from `exposed-modules`, then add a `reexported-modules` field in the same stanza:

```text
reexported-modules: keiro-core:Keiro.Codec
                    keiro-core:Keiro.EventStream
                    keiro-core:Keiro.Integration.Event
                    keiro-core:Keiro.Prelude
                    keiro-core:Keiro.Snapshot.Policy
                    keiro-core:Keiro.Stream
```

Keep `Keiro` itself in `exposed-modules` because `src/Keiro.hs` remains implemented by the `keiro` package. Keep runtime modules in `exposed-modules` because they still live under `src/`.

Compile the `keiro` package after the Cabal edit. If GHC reports ambiguous imports for moved module names, use explicit package imports in the affected runtime source files. For example, if `src/Keiro/Command.hs` cannot resolve `Keiro.Codec`, change that import to:

```haskell
import "keiro-core" Keiro.Codec (Codec, CodecError, decodeRecorded, encodeForAppendWithMetadata)
```

Do the same only for modules that GHC reports as ambiguous; do not package-qualify every import preemptively. The expected likely imports are references from runtime modules to `Keiro.Prelude`, `Keiro.Stream`, `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Integration.Event`, or `Keiro.Snapshot.Policy`.

Milestone 2 is accepted when these commands succeed from the repository root:

```bash
cabal build keiro
cabal test keiro-test
```

Milestone 3 updates sibling packages and documentation. `jitsurei/jitsurei.cabal` can continue to depend only on `keiro` because `keiro` re-exports the moved modules; do not add `keiro-core` there unless a compile error proves a direct dependency is necessary. `keiro-migrations/keiro-migrations.cabal` should not need any change because it does not import `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Stream`, or `Keiro.Integration.Event`. Update `README.md` so the "What it provides" or "Runtime stack" section mentions that reusable contracts live in `keiro-core` and the full runtime lives in `keiro`.

Milestone 3 is accepted when all validation commands listed in "Validation and Acceptance" pass and the plan's living sections are updated with the observed results.


## Concrete Steps

Start from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short
```

If `git status --short` shows unrelated user changes, leave them alone. This plan only needs to modify package metadata, moved module paths, and documentation related to `keiro-core`.

Create the directory layout:

```bash
mkdir -p keiro-core/src/Keiro/Integration keiro-core/src/Keiro/Snapshot
```

Move the core modules with `git mv` so history is preserved:

```bash
git mv src/Keiro/Prelude.hs keiro-core/src/Keiro/Prelude.hs
git mv src/Keiro/Stream.hs keiro-core/src/Keiro/Stream.hs
git mv src/Keiro/Codec.hs keiro-core/src/Keiro/Codec.hs
git mv src/Keiro/EventStream.hs keiro-core/src/Keiro/EventStream.hs
git mv src/Keiro/Integration/Event.hs keiro-core/src/Keiro/Integration/Event.hs
git mv src/Keiro/Snapshot/Policy.hs keiro-core/src/Keiro/Snapshot/Policy.hs
```

If the old empty directories remain under `src/Keiro/Integration` or `src/Keiro/Snapshot`, keep them if other files still exist there. Do not remove a non-empty directory.

Create `keiro-core/keiro-core.cabal` with the library stanza described in "Plan of Work". Then edit `cabal.project`, `mori.dhall`, and `keiro.cabal` as described above.

Run these commands after Milestone 1 edits:

```bash
mori show --full
cabal build keiro-core
```

The relevant `mori show --full` output should include two packages:

```text
Packages (2)
  keiro-core  Library  Haskell
  keiro       Library  Haskell
```

The relevant `cabal build keiro-core` output should end successfully. The exact build log depends on Cabal's cache, but it should not contain `Failed to build`.

Run these commands after Milestone 2 edits:

```bash
cabal build keiro
cabal test keiro-test
```

Run the full validation set after Milestone 3 edits:

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
cabal test keiro-migrations-test
```

If the Cabal solver reports that `keiro` cannot find `keiro-core`, verify that `cabal.project` contains `keiro-core` under `packages`. If GHC reports that a module such as `Keiro.Codec` is hidden because it belongs to a dependency package, verify that `keiro.cabal` includes `keiro-core` in the relevant stanza's `build-depends`.


## Validation and Acceptance

Acceptance is not merely that files moved. The repository must demonstrate both dependency paths:

First, `keiro-core` must build on its own:

```bash
cabal build keiro-core
```

This proves that the core package contains all modules and dependencies it claims to contain.

Second, the full runtime package must still build and pass its tests:

```bash
cabal build keiro
cabal test keiro-test
```

This proves that runtime modules such as `Keiro.Command`, `Keiro.Snapshot`, `Keiro.Router`, `Keiro.ProcessManager`, `Keiro.Inbox`, `Keiro.Outbox`, and `Keiro.Timer` can consume the moved modules through the new package dependency.

Third, the existing examples and migration package must still work:

```bash
cabal test jitsurei-test
cabal test keiro-migrations-test
```

This proves that packages which depend on `keiro` still see the same public import surface after `keiro` re-exports `keiro-core` modules.

Finally, the whole workspace should build:

```bash
cabal build all
```

This proves the package graph is coherent across `keiro-core`, `keiro`, `keiro-migrations`, `jitsurei`, and the benchmark package.

A human can additionally verify the new dependency target by inspecting package metadata:

```bash
cabal list keiro-core --simple-output
```

In a local workspace this command may not show unpublished packages. The authoritative local check is `cabal build keiro-core` plus `mori show --full`, which should list `keiro-core` in this project.


## Idempotence and Recovery

Most edits are ordinary source moves and Cabal metadata updates. Re-running `cabal build` and `cabal test` is safe.

The `git mv` commands are not idempotent: they only work while the files still exist at the original paths. If a move has already happened, do not run it again; inspect with:

```bash
git status --short
rg --files keiro-core/src src/Keiro
```

If a move was partially completed, finish it by moving only the missing files to the destination paths. Do not use `git reset --hard` or `git checkout --` to recover unless the user explicitly asks for destructive rollback.

If `keiro-core` fails to build because a moved module imports a runtime-only dependency, stop and re-evaluate the boundary. The intended recovery is to either leave that module in `keiro` for now or split the runtime-only type out of it. Do not add broad runtime dependencies such as `hasql`, `effectful`, `shibuya-core`, `streamly`, or OpenTelemetry to `keiro-core` just to make the first build pass; that would defeat the purpose of the split.

If `keiro` fails because a moved module is no longer exposed, verify that `keiro.cabal` uses `reexported-modules` for the moved modules and `build-depends` includes `keiro-core`. If a test package fails to import a re-exported module from `keiro`, add an explicit `build-depends: keiro-core` only to that test or package after confirming Cabal cannot resolve the re-export.


## Interfaces and Dependencies

At the end of Milestone 1, `keiro-core/keiro-core.cabal` must define a library named `keiro-core` and expose these modules:

```text
Keiro.Codec
Keiro.EventStream
Keiro.Integration.Event
Keiro.Prelude
Keiro.Snapshot.Policy
Keiro.Stream
```

The following public interfaces must still exist with their current names and modules:

`Keiro.Codec` must export `Codec(..)`, `Upcaster`, `CodecError(..)`, `encodeForAppend`, `encodeForAppendWithMetadata`, `decodeRecorded`, `decodeRaw`, `migrateToCurrent`, `extractSchemaVersion`, and `metadataFor`.

`Keiro.EventStream` must export `EventStream(..)`, `SnapshotPolicy(..)`, and `StateCodec(..)`.

`Keiro.Stream` must export `Stream(..)`, `stream`, `streamName`, and `mapStreamName`.

`Keiro.Integration.Event` must export `IntegrationEvent(..)`, `IntegrationContentType(..)`, `SchemaReference(..)`, `TraceContext(..)`, `IntegrationEventError(..)`, JSON helpers, wire helpers, header constants, `contentTypeText`, and `parseContentType`.

`Keiro.Snapshot.Policy` must export the existing `shouldSnapshot` function. It imports `SnapshotPolicy(..)` from `Keiro.EventStream` and `StreamVersion(..)` from `Kiroku.Store.Types`.

At the end of Milestone 2, `keiro.cabal` must still expose the runtime modules currently in `src/`, including `Keiro`, `Keiro.Command`, `Keiro.Snapshot`, `Keiro.ReadModel`, `Keiro.Projection`, `Keiro.Router`, `Keiro.ProcessManager`, `Keiro.Inbox`, `Keiro.Outbox`, `Keiro.Timer`, and `Keiro.Telemetry`. It must re-export the moved `keiro-core` modules so existing downstream imports through the `keiro` package continue to compile.

The dependency relationship after this plan is:

```text
keiro-core
  depends on: aeson, aeson-casing, base, bytestring, generic-lens, keiki,
              kiroku-store, lens, scientific, text, time, uuid

keiro
  depends on: keiro-core plus runtime dependencies such as effectful, hasql,
              hasql-transaction, hasql-pool, keiki-codec-json, shibuya-core,
              streamly, streamly-core, and OpenTelemetry packages

jitsurei
  depends on: keiro

keiro-migrations
  independent of: keiro and keiro-core
```

Before committing implementation work for this plan, use a Conventional Commit message and include the required trailer:

```text
feat: introduce keiro-core package

Split stable Keiro contracts into the keiro-core package while preserving
the existing keiro import surface through Cabal re-exports.

ExecPlan: docs/plans/29-introduce-keiro-core-package.md
Intention: intention_01ksaq6v2he24v1cczktykp4t7
```
