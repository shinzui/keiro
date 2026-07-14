# Command Cycle

`Keiro.Command` is the central write-side API.

## Public Types

```haskell
data CommandResult target = CommandResult
  { target :: Stream target
  , streamVersion :: StreamVersion
  , globalPosition :: Maybe GlobalPosition
  , eventsAppended :: Int
  }
```

```haskell
data RunCommandOptions = RunCommandOptions
  { retryLimit :: Int
  , pageSize :: Int32
  , eventIds :: [EventId]
  , beforeAppend :: IO ()
  , retryBackoffMicros :: Int
  , metrics :: Maybe KeiroMetrics
  , verifyReplayOnAppend :: Bool
  , tracer :: Maybe Tracer
  , metadata :: Maybe Value
  }
```

`tracer`, when `Just`, opens an OpenTelemetry `Internal`-kind span around each
command invocation (see `Keiro.Telemetry`); when `Nothing`, no spans are emitted.
`metadata`, when `Just`, is JSON merged into every event's metadata for the
invocation (ambient context such as actor type, agent id, or session id); the
codec always adds the `schemaVersion` key, and these keys are merged on top.

`defaultRunCommandOptions` uses:

- `retryLimit = 3`;
- `pageSize = 256`;
- no caller-supplied event ids;
- no `beforeAppend` hook;
- a 5 ms base retry backoff, jittered and capped at 100 ms;
- no metrics handle;
- post-append replay verification enabled;
- no `tracer` (no spans emitted);
- no `metadata`.

`verifyReplayOnAppend` witnesses a bad just-committed batch immediately by
replaying it from the pre-command state. Because the append has committed, a
divergence is reported through telemetry and does not turn success into a
failure. Snapshot-enabled streams always perform the fold because snapshot
creation consumes its final state.

## Running A Command

```haskell
runCommand
  :: (IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co)
  => RunCommandOptions
  -> ValidatedEventStream phi rs s ci co
  -> Stream (EventStream phi rs s ci co)
  -> ci
  -> Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
```

Use `runCommand` when the only write you need is the event append. The stream
argument must be a `ValidatedEventStream`, built with `mkEventStream` or
`mkEventStreamOrThrow`; a bare `EventStream` record does not type-check at the
command boundary. See [Replayability Safety](replay-safety.md).

Use `runCommandWithSql` when you need one SQL continuation in the same
transaction as the append.

Use `runCommandWithSqlEvents` when that continuation needs the decoded output
events as well as the append result.

The transactional runners require `KirokuStoreResource` so they can apply the
store's configured `enrichEvent` hook before preparing the append. Acquire it
with `withKirokuStore` and interpret `Store` with `runStoreResource`. The plain
`runCommand` runner does not add this resource requirement.

See [Build The Command Side](../guides/build-the-command-side.md) for a
guide-backed order stream that exercises `runCommand`, successful appends, and
`CommandRejected` outcomes in `jitsurei`.

## Hydration

Hydration starts from a compatible snapshot if the event stream has a
`stateCodec`; otherwise it reads the stream from version 0.

Every recorded event is:

1. checked against the codec's `eventTypes`;
2. upcast to the current schema version if needed;
3. decoded to the domain event type;
4. replayed through Keiki's streaming replay path.

The command fails if any step fails. Keiro intentionally does not skip bad
events. Streaming replay matters for multi-event Keiki edges: if one command
emitted several stored events, replay carries the in-flight expected tail until
the whole emitted list has been observed.

## Decision

Keiro calls `Keiki.step` with the hydrated `(state, registers)` and the command.

Outcomes:

- `Nothing`: command rejected, returned as `CommandRejected`.
- more than one matching edge: aggregate-definition failure, returned as
  `CommandAmbiguous` with the zero-based edge indices;
- `Just (_, _, events)`: command accepted, where `events` is the list of
  domain events to append. An empty list is an accepted no-op.

Keiro appends the produced event list as one optimistic-concurrency batch, in
the order Keiki returned it. `CommandResult.eventsAppended` is the number of
encoded events appended from that command.

## Append And Retry

Keiro appends with optimistic concurrency:

- empty stream expects `NoStream`;
- existing stream expects the exact hydrated `StreamVersion`.

Retryable conflicts are:

- `WrongExpectedVersion`;
- `StreamAlreadyExists`.

On a retryable conflict, Keiro rehydrates and re-runs the command. This matters:
your command decision must be deterministic for the same stored history.

## Caller-Supplied Event IDs

Set `RunCommandOptions.eventIds` to provide event ids for encoded events.

```haskell
let options =
      defaultRunCommandOptions
        & #eventIds .~ [commandId]
```

Use this for idempotent command submission, process-manager emission, and
replay-safe integration points. If fewer ids are supplied than events, remaining
events use store-generated ids.

## Inline SQL

`runCommandWithSql` runs a continuation inside the append transaction:

```haskell
runCommandWithSql
  defaultRunCommandOptions
  orderEventStream
  orderStream
  command
  (\appendResult -> Tx.statement params updateReadModelStmt)
```

If the continuation condemns the transaction, the event append is rolled back
too. This is the recommended path for strongly consistent inline projections.

`runCommandWithSqlEvents` additionally passes the whole produced domain-event
list in append order:

```haskell
runCommandWithSqlEvents
  options
  eventStream
  target
  command
  (\events appendResult -> traverse_ project events)
```

## Error Handling

`CommandError` values:

- `HydrationDecodeFailed CodecError`: a stored event could not be decoded.
- `HydrationReplayFailed StreamVersion HydrationReplayReason`: replay stalled.
  The reason is `HydrationNoInvertingEdge`, `HydrationAmbiguousInversion`,
  `HydrationQueueMismatch`, or `HydrationTruncatedChain`.
- `HydrationGapDetected expected observed`: stream truncation hid an event not
  covered by the hydration snapshot.
- `CommandRejected`: the transducer rejected the command.
- `CommandAmbiguous edgeIndices`: multiple transitions matched; this is a
  deterministic definition bug, not a normal domain rejection.
- `EncodeFailed CodecError`: a produced event could not be encoded.
- `StoreFailed StoreError`: Kiroku returned a non-retryable store error.
- `RetryExhausted Int StoreError`: retries were exhausted on a conflict.
- `ConflictFixpoint StreamVersion StoreError`: the store reports an existing
  stream but repeated hydration cannot observe progress, commonly because the
  stream was soft-deleted.

Treat hydration failures as data/schema incidents. Treat command rejection as a
domain outcome. Halt and fix ambiguous commands and replay-contract failures.
Treat store failures as infrastructure or concurrency failures, depending on
the underlying `StoreError`.
