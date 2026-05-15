---
id: 12
slug: implement-the-command-cycle-on-kiroku-and-keiki
title: "Implement the command cycle on kiroku and keiki"
kind: exec-plan
created_at: 2026-05-15T15:00:19Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
master_plan: "docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md"
---

# Implement the command cycle on kiroku and keiki

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan implements keiro's central behavior: load a stream's events from kiroku, fold them through keiki into current state, run a command through the transducer, append the emitted events with optimistic concurrency, and retry when another writer wins the race. After completion, an application can call `runCommand` against a real Postgres-backed kiroku store and receive the stream version and global position of the committed event batch.

The behavior is visible in an integration test: a fixture counter or order stream starts empty, a command appends events, a second command observes the prior event through hydration, and a forced expected-version conflict retries and lands exactly once.


## Progress

- [ ] M1 — Implement full hydration from kiroku using `readStreamForwardStream` and `Codec.decodeRecorded`.
- [ ] M2 — Implement pure command evaluation against `Keiki.Core.step` or the current keiki output API.
- [ ] M3 — Implement `runCommand`, expected-version selection, conflict retry, empty-output behavior, and idempotent event ids.
- [ ] M4 — Implement `runCommandWithSql` on `Kiroku.Store.Transaction.runTransactionAppending` for inline projection and outbox consumers.
- [ ] M5 — Add real Postgres-backed integration tests covering create, update, decode failure, conflict retry, and transactional SQL rollback.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Bind the single-stream transactional variant directly to `Kiroku.Store.Transaction.runTransactionAppending`.
  Rationale: The research workaround using singleton `appendMultiStream` is obsolete. Kiroku now exposes the intended append-plus-`Hasql.Transaction.Transaction` primitive.
  Date: 2026-05-15.

- Decision: Keep snapshots out of the first hydration implementation.
  Rationale: EP-13 must prove snapshots are advisory by wrapping a correct full-replay path. EP-12 owns that baseline.
  Date: 2026-05-15.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on EP-10 and EP-11. EP-10 creates the package. EP-11 creates `Keiro.Stream`, `Keiro.Codec`, and `Keiro.EventStream`.

Kiroku source confirms the APIs to use. `Kiroku.Store.Read.readStreamForwardStream :: StreamName -> StreamVersion -> Int32 -> Stream (Eff es) RecordedEvent` reads one stream in ascending `streamVersion` order with an exclusive cursor. Passing `StreamVersion 0` reads the whole stream. `Kiroku.Store.Append.appendToStream :: StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult` appends to one stream. `AppendResult` carries `streamVersion` and `globalPosition` for the last appended event. `Kiroku.Store.Transaction.runTransactionAppending :: StreamName -> ExpectedVersion -> [EventData] -> (AppendResult -> Hasql.Transaction.Transaction a) -> Eff es (Either StoreError a)` atomically combines append with user SQL.

Keiki source confirms the pure core lives in `Keiki.Core`. It exports `SymTransducer`, `RegFile`, `step`, `applyEvent`, `applyEvents`, and `reconstitute`. The implementation must inspect the current signatures before coding; if `step` returns structured errors in the current branch, use them instead of stringly errors.

The command-cycle design is `docs/research/06-command-cycle-design.md`. The codec design is `docs/research/07-codec-strategy.md`. The command-cycle spike under `spikes/command-cycle/` is useful evidence, but production code must use current dependency APIs rather than copying spike stubs blindly.


## Plan of Work

Milestone 1 creates `src/Keiro/Command/Hydrate.hs` or equivalent. Import `Keiro.Prelude` in new keiro modules. Implement a hydration function that takes an `EventStream`, a typed `Stream`, and a page size, reads from `StreamVersion 0`, decodes each `RecordedEvent` with `decodeRecorded`, and folds decoded events into `(s, RegFile rs)` using keiki. The fold must be constant-memory over Streamly, not `Vector` accumulation.

Milestone 2 creates the pure command evaluator. Given the hydrated `(s, RegFile rs)` and a command `ci`, call keiki's current command transition function. The output should be either a command rejection or a list of typed output events `co` plus the updated state/registers if keiki exposes that directly. If keiki exposes only event application and output solving separately, adapt the implementation but keep the public keiro surface stable.

Milestone 3 implements `src/Keiro/Command.hs`. Define `CommandResult` with strict unprefixed fields such as `stream`, `streamVersion`, `globalPosition`, and `eventIds` if appended event ids are available. Define `CommandError` with decode errors, command rejection, store errors, and retry exhaustion. `runCommand` should read the stream, choose `NoStream` for an empty stream or `ExactVersion loadedVersion` for existing streams, encode output events with `Codec.encodeForAppend`, and call `appendToStream`. On `WrongExpectedVersion`, rehydrate and retry up to a configured limit. Empty output should return a no-op result if the command is valid but emits no events; it must not call `appendToStream []`.

Milestone 4 implements `runCommandWithSql`. The function should follow `runCommand` until the append point, then use `runTransactionAppending` so append and caller SQL commit atomically. If the append conflict branch returns `Left StoreError`, retry like `runCommand`. If the user SQL calls `Tx.condemn` or raises a query error, the append must not be visible. Prefer the hook-aware `runTransactionAppendingResource` when the effect stack carries `KirokuStoreResource`; otherwise document which variant is used.

Milestone 5 adds integration tests. Use the same Postgres setup pattern that kiroku or the existing spikes use. The tests must create a store, initialize schema through kiroku's normal `withStore`/resource path, define a small transducer, run commands, and inspect persisted events. Include a transactional SQL test where `runCommandWithSql` inserts into a test table, and a second test where the SQL path fails and no event is appended.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/keiro`, re-check current APIs:

```bash
sed -n '1,260p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Read.hs
sed -n '1,260p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Append.hs
sed -n '1,280p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Transaction.hs
sed -n '1,260p' /Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs
```

Build and test during implementation:

```bash
cabal build all
cabal test all
```

Expected successful test output includes:

```text
keiro-command-integration
  creates a stream and appends first events
  rehydrates state before the second command
  retries a WrongExpectedVersion conflict
  rolls back append when inline SQL fails
```


## Validation and Acceptance

Acceptance requires a passing integration test against real Postgres. The test must prove events are persisted in kiroku, state is recovered by replay rather than in-memory mutation, retry on optimistic conflict works, and `runCommandWithSql` commits or rolls back event append and SQL together.

The implementation must use `readStreamForwardStream` for hydration and `runTransactionAppending` for single-stream transactional append. Records introduced here must import `Keiro.Prelude` and follow the jitsurei record pattern: strict fields, no prefixes, explicit deriving strategies, and lens access/update through `#field`. Using lazy lists, `conduit`, `pipes`, or singleton `appendMultiStream` for the primary path fails acceptance unless recorded as a temporary workaround with a blocking upstream reason.


## Idempotence and Recovery

The integration tests should create isolated stream names and database objects, preferably with unique suffixes. If a test run leaves rows behind, rerunning should either use fresh stream names or clean test-only tables. If a command append returns `DuplicateEvent` during idempotent retry, re-read the stream and classify success only when the intended event is present; otherwise surface an error.


## Interfaces and Dependencies

This plan must expose:

```haskell
module Keiro.Command
  ( CommandResult(..)
  , CommandError(..)
  , RunCommandOptions(..)
  , defaultRunCommandOptions
  , runCommand
  , runCommandWithSql
  )
```

Key dependencies are `Kiroku.Store.Read.readStreamForwardStream`, `Kiroku.Store.Append.appendToStream`, `Kiroku.Store.Transaction.runTransactionAppending`, `Kiroku.Store.Types.ExpectedVersion`, `AppendResult`, `StoreError`, Streamly `Stream`/`Fold`, and keiki's `SymTransducer` execution functions.
