# API Reference

This is a user-facing map of Keiro's public modules. It is not a replacement for
Haddock, but it records which module to import for each task.

## `Keiro`

Top-level convenience module. Re-exports:

- `Keiro.Command`;
- `Keiro.Codec`;
- `EventStream`;
- `Keiro.EventStream.Validate`;
- `SnapshotPolicy`;
- `StateCodec`;
- `Keiro.Router`;
- `Keiro.Snapshot`;
- `Keiro.Stream`.

It also exports `version` (the library version string).

Read-model, projection, process-manager, timer, outbox, inbox, integration-event,
and telemetry APIs are exposed as direct modules and are not re-exported from
`Keiro`.

## `Keiro.Stream`

Types and functions:

- `Stream (..)`
- `stream`
- `streamName`
- `mapStreamName`

Use it to construct typed stream names.

## `Keiro.Codec`

Types and functions:

- `Codec (..)`
- `Upcaster`
- `CodecError (..)`
- `encodeForAppend`
- `encodeForAppendWithMetadata`
- `decodeRecorded`
- `decodeRaw`
- `migrateToCurrent`
- `extractSchemaVersion`
- `metadataFor`

Use it to encode domain events into Kiroku event data and decode recorded
events during hydration or projection handling.

## `Keiro.EventStream`

Types:

- `EventStream (..)`
- `SnapshotPolicy (..)`
- `StateCodec (..)`

Use it to define an aggregate stream contract around a Keiki transducer.

## `Keiro.EventStream.Validate`

Types and functions:

- `EventStreamWarning (..)`
- `ValidatedEventStream`
- `unvalidated`
- `validateEventStream`
- `validateEventStreamWith`
- `mkEventStream`
- `mkEventStreamWith`
- `mkEventStreamOrThrow`
- `mkEventStreamUnchecked`

Use it to turn a raw `EventStream` definition into the `ValidatedEventStream`
required by command runners, projections, routers, and process managers. Prefer
`mkEventStream` in application startup code when you want to handle warnings
explicitly; use `mkEventStreamOrThrow` for generated code and fixtures that have
a sibling validation proof.
`mkEventStreamUnchecked` bypasses every replay-contract check and is reserved
for tests and emergency forensics.

## `Keiro.Command`

Types and functions:

- `CommandResult (..)`
- `CommandError (..)`
- `HydrationReplayReason (..)`
- `RunCommandOptions (..)`
- `defaultRunCommandOptions`
- `runCommand`
- `runCommandWithSql`
- `runCommandWithSqlEvents`

Use it for the canonical load, streaming replay, decide, append command cycle.
Commands may append zero, one, or many produced events as one store batch.
All three runners require `ValidatedEventStream` as their stream argument.
Transactional runners also require `KirokuStoreResource` so Kiroku's configured
event enrichment runs before append preparation.

## `Keiro.Snapshot`

Types and functions:

- `SnapshotSeed (..)`
- `SnapshotMissReason (..)`
- `SnapshotLookup (..)`
- `lookupSnapshotSeed`
- `hydrateWithSnapshot`
- `encodeSnapshotStrict`
- `writeSnapshotEncoded`
- `writeSnapshot`
- re-exports from `Keiro.Snapshot.Codec`;
- re-exports from `Keiro.Snapshot.Schema`.

Most applications use snapshots indirectly through `EventStream.stateCodec` and
`runCommand`.

## `Keiro.Snapshot.Schema`

Types and functions:

- `SnapshotRow (..)`
- `SnapshotWrite (..)`
- `lookupSnapshot`
- `writeSnapshotRow`

Use it for operational tooling. The `keiro_snapshots` table is created by
`keiro-migrate`; see [Database Migrations](migrations.md).

## `Keiro.Projection`

Types and functions:

- `InlineProjection (..)`
- `AsyncProjection (..)`
- `AsyncApplyOutcome (..)`
- `runCommandWithProjections`
- `applyAsyncProjection`
- `applyAsyncProjectionUnfenced`
- `pruneAsyncProjectionDedupBefore`

Use inline projections for same-transaction read-model writes. Use async
projection helpers for at-least-once subscription handlers. `Router` and
`ProcessManager` can also run target inline projections during reactor
dispatch by carrying them in `targetProjections`. Use that field when a reactor
or immediate reader needs read-your-own-writes for the target aggregate after
dispatch. Keep it empty for ordinary fan-out, analytics, reporting tables,
integration publishing, or any projection work that can be eventually
consistent; inline projection SQL runs inside the append transaction and can
slow or fail the dispatch.

## `Keiro.Connection`

Types and functions:

- `qualifyTable`
- `quoteIdentifier`
- `withProjectionSchema`
- `keiroConnectionSettings`
- `ensureProjectionSchema`

Use it to keep application-owned projection tables outside the `kiroku` and
`keiro` framework schemas. Prefer schema-qualified SQL; the connection helpers
can additionally add an application schema to Kiroku's `extraSearchPath`
without changing the event-store schema or notification channel.

## `Keiro.ReadModel`

Types and functions:

- `ReadModel (..)`
- `qualifiedTableName`
- `ConsistencyMode (..)`
- `StrongScope (..)`
- `PositionWaitOptions (..)`
- `ReadModelError (..)`
- `runQuery`
- `runQueryWith`
- `waitFor`
- `readSubscriptionPosition`
- `storeHeadPosition`
- `categoryHeadPosition`
- re-exports from `Keiro.ReadModel.Schema`.

Use it to define typed query wrappers and consistency behavior.

## `Keiro.ReadModel.Schema`

Types and functions:

- `ReadModelMetadata (..)`
- `ReadModelStatus (..)`
- `registerReadModel`
- `lookupReadModel`
- `markRebuilding`
- `markLive`
- `markAbandoned`

Use it for metadata initialization and rebuild lifecycle coordination.

## `Keiro.ReadModel.Rebuild`

Types and functions:

- `RebuildError (..)`
- `startRebuild`
- `finishRebuild`
- `rebuild`
- `promote`
- `abandonRebuild`

Use `startRebuild`, `applyAsyncProjectionUnfenced`, and `finishRebuild` for
supported rebuild jobs. `rebuild` and `promote` are low-level status transitions.

## `Keiro.ProcessManager`

Types and functions:

- `ProcessManager (..)`
- `ProcessManagerAction (..)`
- `ProcessManagerResult (..)`
- `PMCommand (..)`
- `PMCommandResult (..)`
- `PMStateResult (..)`
- `PoisonPolicy (..)`
- `RejectedCommandPolicy (..)`
- `DispatchFailure (..)`
- `WorkerOptions (..)`
- `defaultWorkerOptions`
- `isTransientStoreError`
- `isTransientCommandError`
- `isRejectionClass`
- `decideForFailures`
- `ackForCommandError`
- `deterministicCommandId`
- `eventAlreadyIn`
- `confirmBenignDuplicate`
- `runProcessManagerOnce`
- `runProcessManagerWorkerWith`
- `runProcessManagerWorker`

Use it for event-sourced coordination across streams. `eventAlreadyIn` is the
idempotency point-lookup pre-check, exported so routers and other callers can
reuse it. `runProcessManagerWorkerWith` accepts `WorkerOptions` for
poison-message policy, transient retry delay, and dispatch metrics; the default
worker finalizes each ack exactly once, retries transient store failures, and
halts deterministic failures.
`ProcessManager.targetProjections` is a list of inline projections for target
events only; `[]` preserves append-only dispatch, while a non-empty list gives
read-your-own-writes for target read models updated by process-manager dispatch.
The projections should be small, deterministic writes for the target aggregate's
own read model, not a replacement for async projections or process-manager state
projection.
`RejectedHalt` is the safe default for target rejections. `RejectedDeadLetter`
persists a dispatch witness before acknowledging, while `RejectedSkip`
acknowledges without one. `confirmBenignDuplicate` proves a duplicate event id
belongs to the intended target stream before it is treated as success.

## `Keiro.Router`

Types and functions:

- `Router (..)`
- `RouterResult (..)`
- `runRouterOnce`
- `runRouterWorkerWith`
- `runRouterWorker`

Use it for stateless, effectful fan-out (content-based router / recipient list).
Unlike a process manager, a router resolves its targets *effectfully* (for
example from a read-model `runQuery`) rather than purely from manager state, and
keeps no state stream. `Router.targetProjections` has the same target-only
meaning as the process-manager field: use `[]` for the migration/default path,
or pass the target aggregate's inline projections when router-dispatched writes
must update target read models in the append transaction. `runRouterWorkerWith`
uses the same `WorkerOptions` as process-manager workers. Re-exported from
`Keiro`.

## `Keiro.Timer`

Types and functions:

- `TimerId (..)`
- `TimerRequest (..)`
- `TimerRow (..)`
- `TimerStatus (..)`
- `scheduleTimerTx`
- `claimDueTimer`
- `markTimerFired`
- `runTimerWorker`

Use it for durable timer storage and polling workers.

## `Keiro.DeadLetter`

Types and functions:

- `DispatcherKind (..)`
- `DispatchDeadLetter (..)`
- `DispatchDeadLetterRecord (..)`
- `recordDispatchDeadLetter`
- `listDispatchDeadLetters`

Use it to persist and inspect process-manager/router target rejections when a
worker deliberately selects `RejectedDeadLetter`.

## `Keiro.DeadLetter.Replay`

Types and functions:

- `ReplayOutcome (..)`
- `ReplayResult (..)`
- `DeadLetterRecord (..)`
- `listSubscriptionDeadLetters`
- `replaySubscriptionDeadLetters`

Use it for repeatable operator replay of Kiroku subscription dead letters. The
caller supplies domain decoding/handling and classifies fresh versus duplicate
work; stored rows are retained.

## `Keiro.Integration.Event`

The canonical cross-context integration-event envelope. Exports the envelope
type, `IntegrationContentType (..)`, `SchemaReference (..)`, `TraceContext (..)`,
`IntegrationEventError (..)`, `encodeJsonIntegrationEvent`,
`decodeJsonIntegrationEvent`, `integrationPayload`, `integrationHeaders`, the
`header*` Kafka-header name constants, `contentTypeText`, and `parseContentType`.

Use it to construct and serialize events published across bounded contexts.

## `Keiro.Outbox`

Transactional outbox. Re-exports `Keiro.Outbox.Types` and exports
`enqueueOutboxTx`, `claimOutboxBatch`, `markOutboxSent`,
`lookupOutbox`, `listOutbox`, `freshOutboxId`, `enqueueIntegrationEventTx`,
`IntegrationProducer (..)`, `IntegrationEventDraft (..)`, `mintIntegrationEvent`,
`draftToEvent`, `enqueueProducerEventTx`, `PublishOutcome (..)`,
`publishClaimedOutbox`, `outboxMaintenancePass`, and `sampleOutboxBacklog`.
`Keiro.Outbox.Kafka` adds the Kafka producer adapter.

Use it to commit side-effect intents in the write transaction and publish them
asynchronously with per-key ordering, backoff, dead-lettering, and a separate
maintenance pass for crashed-worker reclamation and backlog sampling.

## `Keiro.Inbox`

Idempotent inbox. Re-exports `Keiro.Inbox.Types` and exports
`lookupInbox`, `listInbox`, `garbageCollectCompleted`,
`runInboxTransaction`, and `runInboxTransactionWithKey`. `Keiro.Inbox.Kafka` adds
the Kafka consumer adapter.

Use it to deduplicate inbound integration events by `(source, dedupe_key)`.

## `Keiro.Telemetry`

OpenTelemetry instrumentation. Exports span helpers, W3C trace-context
propagation, semantic-convention attribute-name constants, `KeiroMetrics`,
`newKeiroMetrics`, and `record*` helpers for the `keiro.*` metric instruments.
Process-manager and router workers can record `keiro.dispatch.failed`,
`keiro.dispatch.duplicates`, and `keiro.dispatch.poison` through
`WorkerOptions.metrics`.

## `Keiro.Migrations` (package `keiro-migrations`)

Native `pg-migrate` component and the standard `keiro-migrate` executable.
Exports `keiroMigrations` and `frameworkMigrationPlan`.
`Keiro.Migrations.History.Codd` exports the exact legacy evidence and combined
Kiroku/Keiro import mapping used during cutover.

Use it to compose Kiroku first and Keiro second, apply or strictly verify the
plan, and import an existing shared Codd ledger without replaying SQL.

## `Keiro.Dsl.*` (package `keiro-dsl`)

The library exposes the grammar, parser, pretty-printer, validator, diff
classifier, scaffolder, scaffold planner/runner, manifest, read-model shape,
starter skeleton, and harness modules. Most applications use the `keiro-dsl`
executable instead: `parse`, `check`, `scaffold`, `diff --since`, and
`new <kind>`. See [Typed Specifications](typed-spec-toolchain.md).

## `Keiro.Prelude`

Project prelude used by Keiro modules. Application code may import it when
following the repository's style, but it is not required to use Keiro.
