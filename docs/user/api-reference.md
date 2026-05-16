# API Reference

This is a user-facing map of Keiro's public modules. It is not a replacement for
Haddock, but it records which module to import for each task.

## `Keiro`

Top-level convenience module. Re-exports:

- `Keiro.Command`;
- `Keiro.Codec`;
- `EventStream`;
- `SnapshotPolicy`;
- `StateCodec`;
- `Keiro.Snapshot`;
- `Keiro.Stream`.

Read-model, projection, process-manager, and timer APIs are exposed as direct
modules and are not re-exported from `Keiro`.

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

## `Keiro.Command`

Types and functions:

- `CommandResult (..)`
- `CommandError (..)`
- `RunCommandOptions (..)`
- `defaultRunCommandOptions`
- `runCommand`
- `runCommandWithSql`
- `runCommandWithSqlEvents`

Use it for the canonical load, replay, decide, append command cycle.

## `Keiro.Snapshot`

Types and functions:

- `SnapshotSeed (..)`
- `hydrateWithSnapshot`
- `writeSnapshot`
- re-exports from `Keiro.Snapshot.Codec`;
- re-exports from `Keiro.Snapshot.Schema`.

Most applications use snapshots indirectly through `EventStream.stateCodec` and
`runCommand`.

## `Keiro.Snapshot.Schema`

Types and functions:

- `SnapshotRow (..)`
- `SnapshotWrite (..)`
- `initializeSnapshotSchema`
- `lookupSnapshot`
- `writeSnapshotRow`

Use it for schema initialization or operational tooling.

## `Keiro.Projection`

Types and functions:

- `InlineProjection (..)`
- `AsyncProjection (..)`
- `runCommandWithProjections`
- `applyAsyncProjection`

Use inline projections for same-transaction read-model writes. Use async
projection helpers for at-least-once subscription handlers.

## `Keiro.ReadModel`

Types and functions:

- `ReadModel (..)`
- `ConsistencyMode (..)`
- `PositionWaitOptions (..)`
- `ReadModelError (..)`
- `runQuery`
- `runQueryWith`
- `waitFor`
- re-exports from `Keiro.ReadModel.Schema`.

Use it to define typed query wrappers and consistency behavior.

## `Keiro.ReadModel.Schema`

Types and functions:

- `ReadModelMetadata (..)`
- `ReadModelStatus (..)`
- `initializeReadModelSchema`
- `registerReadModel`
- `lookupReadModel`
- `markRebuilding`
- `markLive`
- `markAbandoned`

Use it for metadata initialization and rebuild lifecycle coordination.

## `Keiro.ReadModel.Rebuild`

Functions:

- `rebuild`
- `promote`
- `abandonRebuild`

Use it for read-model lifecycle transitions around rebuild jobs.

## `Keiro.ProcessManager`

Types and functions:

- `ProcessManager (..)`
- `ProcessManagerAction (..)`
- `ProcessManagerResult (..)`
- `PMCommand (..)`
- `PMCommandResult (..)`
- `PMStateResult (..)`
- `deterministicCommandId`
- `runProcessManagerOnce`
- `runProcessManagerWorker`

Use it for event-sourced coordination across streams.

## `Keiro.Timer`

Types and functions:

- `TimerId (..)`
- `TimerRequest (..)`
- `TimerRow (..)`
- `TimerStatus (..)`
- `initializeTimerSchema`
- `scheduleTimerTx`
- `claimDueTimer`
- `markTimerFired`
- `runTimerWorker`

Use it for durable timer storage and polling workers.

## `Keiro.Prelude`

Project prelude used by Keiro modules. Application code may import it when
following the repository's style, but it is not required to use Keiro.
