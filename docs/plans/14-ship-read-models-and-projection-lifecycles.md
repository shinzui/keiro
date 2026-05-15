---
id: 14
slug: ship-read-models-and-projection-lifecycles
title: "Ship read models and projection lifecycles"
kind: exec-plan
created_at: 2026-05-15T15:00:25Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
master_plan: "docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md"
---

# Ship read models and projection lifecycles

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan gives keiro a usable read side. After completion, an application can define a typed `ReadModel q r`, update it through inline or async projections, query it through `runQuery`, and choose read consistency explicitly: strong inline consistency, eventual async consistency, or async plus position-wait using the `GlobalPosition` returned by `runCommand`.

The behavior is visible in tests: an inline projection row is queryable immediately after command return; an async projection eventually advances its subscription cursor; and `PositionWait` blocks until `subscriptions.last_seen` reaches the requested global position or returns a timeout.


## Progress

- [x] M1 — Add `Keiro.ReadModel` with `ReadModel q r`, `ConsistencyMode`, `runQuery`, `runQueryWith`, and `waitFor`. Completed 2026-05-15.
- [x] M2 — Add `keiro_read_models` metadata schema and stale-schema checks. Completed 2026-05-15.
- [x] M3 — Add inline projection registration that runs through EP-12 `runCommandWithSql`. Completed 2026-05-15.
- [x] M4 — Add async projection helpers with at-least-once semantics and idempotency-token guidance. Completed 2026-05-15.
- [x] M5 — Add rebuild protocol skeleton in `Keiro.ReadModel.Rebuild`. Completed 2026-05-15.
- [x] M6 — Add integration tests for inline, eventual, position-wait success, position-wait timeout, stale schema, and idempotent async writes. Completed 2026-05-15.


## Surprises & Discoveries

- 2026-05-15: EP-14 needed a small `Keiro.Command.runCommandWithSqlEvents` helper so inline projection handlers can receive decoded output events as well as the `AppendResult`. The existing `runCommandWithSql` API remains as the append-result-only wrapper.

- 2026-05-15: Shibuya's core `Adapter`/`Handler` API remains independent of kiroku subscription checkpoint transactions, so the v1 async projection API is intentionally a direct `RecordedEvent -> Tx.Transaction ()` boundary plus idempotency key guidance. The integration test drives duplicate delivery directly through kiroku events instead of claiming exactly-once shibuya handling.


## Decision Log

- Decision: Ship exactly-once inline projections and at-least-once async projections in v1.
  Rationale: Kiroku has the transaction primitive needed for inline projections. Shibuya's transactional subscription handler shape is still open, so exactly-once async checkpoint plus side effect remains a later enhancement.
  Date: 2026-05-15.

- Decision: Treat read-model stale schema as an error, unlike snapshots.
  Rationale: Read models are user-queryable data. Serving rows whose shape no longer matches the compiled query type is worse than failing early.
  Date: 2026-05-15.

- Decision: Keep `Keiro.ReadModel` as a direct public module rather than re-exporting it from the top-level `Keiro` module.
  Rationale: `ReadModel` and `ReadModelMetadata` both have a `version` field, which collides with the existing top-level `Keiro.version` binding under broad re-export. Direct module imports preserve the public API without creating ambiguous imports for existing users.
  Date: 2026-05-15.


## Outcomes & Retrospective

EP-14 shipped the v1 read side. The library now exposes `Keiro.ReadModel`, `Keiro.Projection`, and `Keiro.ReadModel.Rebuild`, plus Cabal exports for those modules. `Keiro.ReadModel.Schema.initializeReadModelSchema` creates the `keiro_read_models` metadata table, query execution registers live metadata on first use, and stale version or shape-hash metadata returns `ReadModelStaleSchema`.

Inline projections run through `runCommandWithProjections`, which delegates to the same `runTransactionAppending` path as EP-12's `runCommandWithSql`, so projection SQL rolls back with the event append. Async projections are at-least-once helpers over `RecordedEvent` and `Tx.Transaction`; the test suite proves the `source_event_id UUID UNIQUE` idempotency pattern by applying the same recorded event twice and observing one read-model update.

Validation passed with `cabal test all` on 2026-05-15. The focused keiro output includes the new `Keiro.ReadModel` examples for Strong inline query visibility, PositionWait success, PositionWait timeout, stale schema rejection, duplicate async delivery, and rebuild state transitions.


## Context and Orientation

This plan depends on EP-12 because it needs `CommandResult.globalPosition` and `runCommandWithSql`. It consumes `docs/research/08-subscription-and-process-manager-design.md` and `docs/research/12-read-model-query-api-and-lifecycle.md`.

A projection is code that observes events and writes derived read-side rows. A read model is the queryable artifact backed by those rows. In keiro, inline projections run in the same transaction as the command append; async projections run later from a subscription worker. A subscription cursor in kiroku records how far a worker has processed the global event stream. `PositionWait` is a consistency mode where the caller asks keiro to wait until the relevant cursor has reached the command's returned `GlobalPosition`.

Kiroku's `GlobalPosition` is gap-free and strictly increasing. Kiroku's subscription table is named `subscriptions` in the research docs and stores a `subscription_name` and `last_seen` cursor. Verify the current schema in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Schema.hs` before writing SQL. Shibuya's handler shape is `type Handler es msg = Ingested es msg -> Eff es AckDecision`, where `Ingested` carries an `Envelope msg`, ack handle, and optional lease. The current shibuya API does not let a handler fold checkpoint advancement into the user's hasql transaction.


## Plan of Work

Milestone 1 creates `src/Keiro/ReadModel.hs`. Import `Keiro.Prelude`. Define `ReadModel q r` as a strict record carrying a stable `name`, `tableName`, `subscriptionName`, `version`, `shapeHash`, `defaultConsistency`, and a function that turns a query `q` into a hasql transaction or session returning `r`. Do not use `rm` field prefixes. Define `ConsistencyMode = Strong | Eventual | PositionWait PositionWaitOptions` or equivalent. `runQuery` should use the default mode; `runQueryWith` should accept an override and optional target `GlobalPosition`.

Milestone 2 creates schema support. Add `keiro_read_models(name, version, shape_hash, last_built_at, status)` and functions to register/check a model. On query, compare the compiled version/hash to the database row. Missing metadata can insert a live row during initialization, but a mismatched row must return a `ReadModelStaleSchema` error.

Milestone 3 adds inline projections. Define a small `InlineProjection co` record whose handler receives decoded event(s), the `AppendResult`, and writes hasql transaction work. Provide `runCommandWithProjections` as sugar over EP-12's `runCommandWithSql`. A failing projection rolls back the append because it runs in the same transaction.

Milestone 4 adds async projection helpers. Provide enough API to run a projection from a kiroku/shibuya subscription with at-least-once behavior. Require idempotency by documenting and testing the `source_event_id UUID NOT NULL UNIQUE` pattern from `docs/research/12-read-model-query-api-and-lifecycle.md`. If the shibuya-kiroku adapter exposes a usable source, consume it; otherwise create an adapter boundary and a direct kiroku polling test harness without pretending exactly-once async exists.

Milestone 5 adds `Keiro.ReadModel.Rebuild`. Implement the metadata-state transitions and function skeletons for shadow-table rebuild, pause/resume hooks, promote, abandon, and retire. The full operator CLI can wait, but library calls and tests should prove stale schema detection and basic rebuild state transitions.

Milestone 6 tests the full read side. Use real Postgres. The fixture should append an event with `runCommand`, update an inline read-model row, query it immediately, run an async projection over the same event stream, and test `waitFor` by advancing a subscription cursor. Include a timeout test using a target position greater than the cursor.


## Concrete Steps

Inspect current source before implementing:

```bash
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Schema.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Handler.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Adapter.hs
```

Run:

```bash
cabal build all
cabal test all
```

Expected focused output:

```text
keiro-read-model-integration
  queries inline projection with Strong consistency
  waits for async projection cursor with PositionWait
  times out when cursor does not advance
  rejects stale read-model schema
  ignores duplicate async event by source_event_id
```


## Validation and Acceptance

Acceptance requires public `Keiro.ReadModel` APIs, keiro-owned metadata schema, inline projection tests proving same-transaction behavior, and position-wait tests proving both success and timeout. Async projection behavior may be at-least-once, but the tests must prove duplicate delivery is safe with an idempotency key. New modules must import `Keiro.Prelude`; records such as `ReadModel`, `PositionWaitOptions`, `InlineProjection`, and `AsyncProjection` must use strict unprefixed fields with explicit deriving strategies and `#field` access/update.

Do not claim exactly-once async projections until a shibuya-kiroku transactional handler shape exists and keiro consumes it.


## Idempotence and Recovery

Schema initialization must be repeatable. Async projection handlers must be safe to rerun for the same event. Rebuild operations should be state-machine-like: rerunning a failed rebuild either resumes from a known status or returns a clear error explaining the current status. Timeout tests must use short bounded durations so a failing worker does not hang the suite.


## Interfaces and Dependencies

This plan must expose:

```haskell
module Keiro.ReadModel
  ( ReadModel(..)
  , ConsistencyMode(..)
  , PositionWaitOptions(..)
  , ReadModelError(..)
  , runQuery
  , runQueryWith
  , waitFor
  )

module Keiro.Projection
  ( InlineProjection(..)
  , AsyncProjection(..)
  , runCommandWithProjections
  )

module Keiro.ReadModel.Rebuild
  ( rebuild
  , promote
  , abandonRebuild
  )
```

Dependencies include EP-12 `runCommandWithSql`, `Kiroku.Store.Types.GlobalPosition`, kiroku subscription cursor storage, hasql statements for read-model tables, and shibuya adapter/handler types for worker integration.
