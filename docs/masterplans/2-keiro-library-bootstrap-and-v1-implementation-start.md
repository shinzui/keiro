---
id: 2
slug: keiro-library-bootstrap-and-v1-implementation-start
title: "keiro Library Bootstrap and v1 Implementation Start"
kind: master-plan
created_at: 2026-05-15T15:00:06Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
---

# keiro Library Bootstrap and v1 Implementation Start

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

This initiative turns keiro from a research repository into a compiling Haskell library that applications can import to run the first production-shaped event-sourcing path. After it completes, a caller can define a typed `EventStream`, submit a command through `runCommand`, have keiro load events from kiroku, fold them through keiki, append new events with optimistic concurrency, optionally update inline projection SQL in the same transaction, and query read models with explicit consistency modes. The library also has the storage and public modules needed for snapshots, process-manager state, and timer-backed v1 workflow orchestration.

The scope is deliberately v1-focused. It includes the Cabal/package bootstrap, the public `Keiro.*` module surface, the `EventStream` and codec contract, the canonical command cycle, advisory snapshots, read models and projection lifecycles, process managers, and durable timers. It excludes the v2 deterministic durable-execution runtime (`Workflow es a`, named-step journal replay, awakeables, and child workflows) except where the v1 timer and process-manager design keeps the upgrade path open. It also excludes upstream implementation work in keiki, kiroku, and shibuya, because those repositories are being changed in parallel; this MasterPlan records the exact upstream APIs keiro consumes and which still-open gaps are tolerated by v1 workarounds.

The implementation inherits the completed research foundation in `docs/masterplans/1-keiro-research-foundation.md` and `docs/research/06-command-cycle-design.md` through `docs/research/12-read-model-query-api-and-lifecycle.md`. The current dependency state matters: kiroku now exposes `Kiroku.Store.Transaction.runTransactionAppending`, `Kiroku.Store.Read.readStreamForwardStream`, `Kiroku.Store.Read.lookupStreamId`, interpreter hooks in `Kiroku.Store.Settings`, and causation walkers; keiki now exposes `Keiki.Shape.regFileShapeHash` and the sibling `keiki-codec-json` package with `Keiki.Codec.JSON.regFileToJSON` and `regFileFromJSON`. The shibuya transactional subscription-handler shape remains open, so exactly-once async projections are not a v1 acceptance gate.


## Decomposition Strategy

The decomposition follows the runtime path a keiro user exercises, not the eventual file tree. EP-10 bootstraps the package and test harness so every other plan has a real library to extend. EP-11 defines the public authoring contract (`Stream`, `Codec`, `EventStream`, snapshot policy placeholders, and errors) without talking to the database. EP-12 implements the command cycle that consumes EP-11 and proves the central write path against kiroku and keiki. EP-13 adds advisory snapshots as an optimization of EP-12's hydration phase. EP-14 adds read models and projection lifecycles on top of EP-12's returned `GlobalPosition` and transactional append hook. EP-15 adds process managers and durable timers, reusing EP-12's command path and EP-14's projection/subscription substrate.

This shape keeps parallel work possible after the foundation lands. EP-13 can proceed once EP-12 exposes a hydration hook and EP-11 exposes `SnapshotPolicy`/`StateCodec`. EP-14 can proceed once EP-12 returns `GlobalPosition` and implements `runCommandWithSql`. EP-15 can start its pure process-manager API after EP-11, but its end-to-end runner waits on EP-12 and its subscription wiring aligns with EP-14.

Alternatives considered:

- A single implementation ExecPlan. Rejected because bootstrapping, command writes, snapshots, read-side consistency, and workflow/process-manager orchestration have different validation stories and would create an oversized plan.
- A separate plan for codecs and a separate plan for `EventStream`. Rejected because the implementation contract is one public authoring surface; splitting it would make both plans modify the same modules and force artificial dependencies.
- Implement read models before snapshots. Accepted as a possible execution order but not a dependency inversion: snapshots are internal/advisory and read models are user-facing. They can proceed in parallel after EP-12 because they do not share tables or correctness semantics.
- Block all async projection work on shibuya's transactional handler gap. Rejected because keiro can ship inline projections and at-least-once async projections with idempotency now, while recording exactly-once async as a later enhancement.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 10 | Bootstrap the keiro Haskell package | docs/plans/10-bootstrap-the-keiro-haskell-package.md | None | None | Complete |
| 11 | Define the EventStream contract and codec surface | docs/plans/11-define-the-eventstream-contract-and-codec-surface.md | EP-10 | None | Not Started |
| 12 | Implement the command cycle on kiroku and keiki | docs/plans/12-implement-the-command-cycle-on-kiroku-and-keiki.md | EP-10, EP-11 | None | Not Started |
| 13 | Add snapshots and accelerated hydration | docs/plans/13-add-snapshots-and-accelerated-hydration.md | EP-10, EP-11, EP-12 | EP-9 | Not Started |
| 14 | Ship read models and projection lifecycles | docs/plans/14-ship-read-models-and-projection-lifecycles.md | EP-10, EP-11, EP-12 | EP-13 | Not Started |
| 15 | Build process managers and timer workflows | docs/plans/15-build-process-managers-and-timer-workflows.md | EP-10, EP-11, EP-12 | EP-14 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference other rows by their `EP-N` prefix. EP-9 is the existing queued plan at `docs/plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md`; it is listed only as a soft dependency because the upstream primitives have now landed locally, but the plan still contains useful usage guidance for snapshot integration.


## Dependency Graph

EP-10 is first and hard-blocks every implementation plan because keiro currently has no Cabal package, no `src/` tree, and no test harness. All later plans need `keiro.cabal`, `cabal.project`, source directories, and CI/developer commands.

EP-11 hard-depends on EP-10 and defines the public contract later plans consume: the typed `Stream a` wrapper around `Kiroku.Store.Types.StreamName`, the value-level `Codec e`, the `EventStream phi rs s ci co` record around `Keiki.Core.SymTransducer`, snapshot policy types, command/read-model error types, and authoring helpers. EP-12 cannot compile without these types.

EP-12 hard-depends on EP-10 and EP-11. It implements hydration using `Kiroku.Store.Read.readStreamForwardStream`, folding decoded events with `Keiki.Core.applyEvent` / `applyEvents`, appending with `Kiroku.Store.Append.appendToStream`, and transactional command variants with `Kiroku.Store.Transaction.runTransactionAppending`. EP-13, EP-14, and EP-15 all depend on its result type carrying the final `StreamVersion` and `GlobalPosition`.

EP-13 hard-depends on EP-12 because snapshots accelerate the hydration phase rather than replacing it. A failed snapshot read must fall through to EP-12's full replay. EP-13 soft-depends on EP-9 because EP-9 records the `keiki-codec-json` usage guidance, but EP-13 can consume `Keiki.Codec.JSON` directly if EP-9 remains queued.

EP-14 hard-depends on EP-12 because read-after-write consistency waits on the `GlobalPosition` returned by `runCommand`, and inline projections must use `runCommandWithSql` so event append and read-model row update commit together. EP-14 soft-depends on EP-13 because read-model rebuilds borrow the "shape hash guards stale data" pattern, while snapshots and read models use different tables and different failure semantics.

EP-15 hard-depends on EP-12 because process managers emit commands to ordinary event streams through `runCommand`. It soft-depends on EP-14 because async process-manager runners share subscription and idempotency conventions with projection workers, but the pure process-manager state machine can be built before the final read-model API lands.

Plans that can proceed in parallel: after EP-10 and EP-11 complete, EP-12 is the next critical-path plan. After EP-12 exposes `runCommand`, `runCommandWithSql`, and `hydrate`, EP-13 and EP-14 can proceed independently, and EP-15 can start its pure API while waiting for EP-14's worker conventions.


## Integration Points

**Public module index, prelude, and Cabal exports.** EP-10 owns `keiro.cabal`, `cabal.project`, `src/Keiro.hs`, `src/Keiro/Prelude.hs`, and the initial test executable. `Keiro.Prelude` must follow `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md`: use `PackageImports`, re-export common imports through `module X`, import `Data.Generics.Labels ()`, and re-export `Control.Lens`. EP-11 through EP-15 extend the exposed module list but must preserve EP-10's warnings, language extensions, dependency bounds, prelude import discipline, and test layout.

**`Keiro.EventStream` contract.** EP-11 owns `Keiro.EventStream`, including `Stream a`, `EventStream phi rs s ci co`, `Codec co`, `SnapshotPolicy`, and `StateCodec`. The implementation must follow `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`: no field prefixes, strict record fields, explicit deriving strategies, `DuplicateRecordFields`, `OverloadedLabels`, and lens-style updates through `#field` rather than record update syntax. New modules should import `Keiro.Prelude` instead of repeating common imports. EP-12 consumes the command-relevant fields. EP-13 fills in snapshot behavior behind the policy and codec fields. EP-14 and EP-15 reuse the typed `Stream a` for read-model and process-manager references.

**`Keiro.Command` result and error model.** EP-12 owns `CommandResult` and `CommandError`. EP-13 may add snapshot warning details but must not make snapshot failure a command failure. EP-14 consumes `CommandResult.globalPosition` for `PositionWait` read-model consistency. EP-15 wraps command errors when process managers emit target commands.

**Kiroku transaction boundary.** EP-12 owns `runCommandWithSql`, binding single-stream commands to `Kiroku.Store.Transaction.runTransactionAppending` or `runTransactionAppendingResource`. EP-14 consumes that boundary for inline projections. EP-15 consumes it for timer/outbox writes associated with process-manager state transitions.

**`keiro_snapshots` table.** EP-13 owns the table and `Keiro.Snapshot` modules. No read-model or projection plan may store user query data in `keiro_snapshots`; snapshots are advisory internal acceleration only.

**`keiro_read_models` table and consistency modes.** EP-14 owns `Keiro.ReadModel`, `Keiro.ReadModel.Rebuild`, `ConsistencyMode`, and the metadata table. EP-15 may rely on read models for examples but must not couple process-manager correctness to read-model freshness.

**Process-manager state streams and timer table.** EP-15 owns `Keiro.ProcessManager`, `Keiro.Timer`, the `pm-<name>-<correlation>` stream naming convention, and `keiro_timers`. It consumes EP-12's command path and EP-14's subscription conventions but does not redefine them.

**Streamly substrate.** Every multi-event path must use Streamly because kiroku and shibuya already expose `Streamly.Data.Stream.Stream`. EP-12 uses `readStreamForwardStream`; EP-13 reuses the same stream/fold with a later cursor when a snapshot is valid; EP-14 and EP-15 use shibuya adapters and Streamly folds for worker loops. Modules that expose keiro's typed `Stream a` and also need Streamly must import Streamly qualified.


## Progress

- [x] EP-10: create `keiro.cabal`, `cabal.project`, source tree, test tree, and developer commands.
- [x] EP-10: prove `cabal build all`, `cabal test all`, and existing docs build commands work from the repository root.
- [ ] EP-11: implement `Keiro.Stream`, `Keiro.Codec`, `Keiro.EventStream`, snapshot policy placeholders, and public re-exports.
- [ ] EP-11: add pure unit tests for stream-name conversion, codec round trips, upcaster ordering, and EventStream construction.
- [ ] EP-12: implement hydration, `runCommand`, retry-on-conflict, idempotent event ids, and `runCommandWithSql`.
- [ ] EP-12: prove the command cycle against a real Postgres-backed kiroku store with a fixture transducer.
- [ ] EP-13: create `keiro_snapshots`, read/write snapshot functions, and fallback-to-full-replay hydration.
- [ ] EP-13: prove snapshot round trip and stale-snapshot fallback against real Postgres.
- [ ] EP-14: implement inline, eventual, and position-wait read-model query modes plus projection idempotency helpers.
- [ ] EP-14: prove read-after-write behavior for inline and async projections.
- [ ] EP-15: implement process-manager state streams, deterministic emitted-command ids, durable timers, and the worker-facing API.
- [ ] EP-15: prove a fixture process manager schedules a timer and emits an idempotent command after the timer fires.


## Surprises & Discoveries

- EP-10 found that unreleased sibling packages still need local `cabal.project` entries, but Hackage packages should be used wherever available. The final project file keeps local entries only for `keiki`, `keiki-codec-json`, and `kiroku-store`; `shibuya-core`, Hasql packages, Effectful, and ordinary libraries resolve from Hackage.

- EP-10 found that keiki's local packages needed `time ^>=1.14` for the GHC 9.12 environment. The sibling `keiki.cabal`, `keiki-codec-json.cabal`, and `jitsurei.cabal` bounds were updated.

- EP-10 found that full `cabal test all` runs local dependency tests and keiki's symbolic tests require Z3. `flake.nix` now includes `pkgs.z3`, and `nix develop -c cabal test all` passes.


## Decision Log

- Decision: Start implementation with six child ExecPlans: package bootstrap, EventStream/codec contract, command cycle, snapshots, read models/projections, and process managers/timers.
  Rationale: The research foundation already split design surfaces. The implementation split keeps the first compiling package small, then exposes independently verifiable behaviors while preserving the dependency order implied by the runtime path.
  Date: 2026-05-15.

- Decision: Treat shibuya's transactional subscription-handler shape as a non-blocking enhancement, not a blocker for this MasterPlan.
  Rationale: Inline projections can be exactly transactional through `runCommandWithSql`, and async projections can ship at-least-once with idempotency tokens. Blocking all read-side work on exactly-once async handling would serialize keiro on an upstream change that is not required for the first usable library.
  Date: 2026-05-15.

- Decision: Use `runTransactionAppending` as the single-stream transactional command primitive and reserve `appendMultiStream` for multi-stream command extensions.
  Rationale: Kiroku now ships the exact single-stream append-plus-SQL transaction wrapper requested by the research foundation. The old singleton `appendMultiStream` workaround should not enter new implementation plans.
  Date: 2026-05-15.


## Outcomes & Retrospective

(To be filled during and after implementation.)
