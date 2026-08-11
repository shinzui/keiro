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

Outcome-aware handlers add an application result without changing
`CommandResult` or `CommandError`:

```haskell
data DomainDecision event rejection noOp
  = DomainAccepted (NonEmpty event)
  | DomainRejected rejection
  | DomainNoOp noOp

data DomainCommandOutcome target event rejection noOp = DomainCommandOutcome
  { decision :: DomainDecision event rejection noOp
  , result :: CommandResult target
  }

data DomainCommandHandler phi rs state command event rejection noOp =
  DomainCommandHandler
    { eventStream :: ValidatedEventStream phi rs state command event
    , classifySilent
        :: SilentCommandContext rs state command
        -> SilentDomainDecision rejection noOp
    }
```

`DomainAccepted` contains the exact non-empty values encoded and appended, in
order. `DomainRejected` and `DomainNoOp` come only from an explicitly selected,
state-preserving live edge that emits no events. The pure `classifySilent`
function receives the pre-command state/registers, command, and exact selected
`EdgeRef`; it does not choose an edge or run a guard again.

```haskell
data RunCommandOptions = RunCommandOptions
  { retryLimit :: Int
  , pageSize :: Int32
  , eventIds :: [EventId]
  , beforeAppend :: IO ()
  , retryBackoffMicros :: Int
  , metrics :: Maybe KeiroMetrics
  , verifyReplayOnAppend :: Bool
  , seedVerifySampleRate :: Int
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
- one asynchronous snapshot-seed verification per 1000 snapshot hits;
- no `tracer` (no spans emitted);
- no `metadata`.

`verifyReplayOnAppend` witnesses a bad just-committed batch immediately by
replaying it from the pre-command state. Because the append has committed, a
divergence is reported through telemetry and does not turn success into a
failure. Snapshot-enabled streams always perform the fold because snapshot
creation consumes its final state.

`seedVerifySampleRate` is the amortized backstop for a snapshot discriminator
that was accidentally left unchanged across a hand-written fold edit. A sampled
snapshot hit full-replays only through the snapshot version in a background
thread and compares canonical encoded `(state, registers)`. A mismatch emits
`keiro.snapshot.seed.divergence` and a structured log containing the stream,
seed version, and both SHA-256 digests. It never blocks the command and never
writes a snapshot. Set the rate to `1` to verify every hit or `0` to disable it.

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

Use `runDomainCommand` with a `DomainCommandHandler` when the caller must
distinguish accepted, application-rejected, and successful no-op decisions:

```haskell
runDomainCommand
  :: RunCommandOptions
  -> DomainCommandHandler phi rs state command event rejection noOp
  -> Stream (EventStream phi rs state command event)
  -> command
  -> Eff es
       (Either
          CommandError
          (DomainCommandOutcome
             (EventStream phi rs state command event)
             event
             rejection
             noOp))
```

`forgetDomainDecision` collapses any successfully selected domain decision to
its ordinary `CommandResult`. Apply it under the outer `Either` with `fmap`.
An unmatched command remains `Left CommandRejected` and never reaches the
adapter.

For a candidate-language-5 aggregate with a `domain-outcomes` declaration,
`keiro-dsl scaffold` constructs this handler in the generated event-stream
module and exports it under the normalized aggregate name. For example:

```haskell
import Generated.Reservations.Reservation.EventStream
  ( reservationDomainCommandHandler )

result <-
  runDomainCommand
    defaultRunCommandOptions
    reservationDomainCommandHandler
    reservationStream
    command
```

The generated classifier does not re-evaluate a guard. It matches the exact
`EdgeRef` selected by Keiki with a direct state/index `case` and evaluates only
that edge's checked reason term using the pre-command registers and command.
Accepted edges bypass the classifier; `runDomainCommand` owns the returned
non-empty event batch. Rejected/no-op edges are state-preserving and emit
nothing, so they open no append transaction.

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
`CommandRejected` outcomes in `jitsurei`. The outcome-aware example is
`Jitsurei.OrderStream.orderDomainCommandHandler`; its exhaustive
`renderOrderDecision` function handles all three decisions, and the Jitsurei
test proves only `DomainAccepted` reaches the inline projection.

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

Keiro evaluates the hydrated `(state, registers)` and command once. The legacy
runner erases the selected-edge detail and returns:

Outcomes:

- `Nothing`: command rejected, returned as `CommandRejected`.
- more than one matching edge: aggregate-definition failure, returned as
  `CommandAmbiguous` with the zero-based edge indices;
- `Just (_, _, events)`: command accepted, where `events` is the list of
  domain events to append. An empty list is an accepted no-op.

The outcome-aware runner keeps the detailed success instead:

- a selected edge with one or more events becomes `DomainAccepted`;
- a selected edge with no events is classified exactly once as
  `DomainRejected` or `DomainNoOp`;
- no outgoing edge or no matching edge remains `Left CommandRejected`;
- more than one matching edge remains `Left (CommandAmbiguous indices)`.

A selected silent edge is therefore a positive domain decision. An unmatched
command is still a partial command protocol and has no application payload.
Validated streams reject silent edges that change durable state.

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
your command decision must be deterministic for the same stored history. A
domain runner returns only the decision from the attempt that commits or the
final selected silent decision; it discards any accepted batch from a stale
conflicting attempt.

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

The parallel `runDomainCommandWithSql` and
`runDomainCommandWithSqlEvents` functions run their callbacks only for an
accepted append and return `Nothing` for the callback result on rejection or
no-op. `runDomainCommandWithSqlEventsControlled` additionally distinguishes a
committed accepted outcome from a catalog/fence rollback; a rollback cannot
fabricate a `DomainCommandOutcome` because no append committed.

Likewise, `runDomainCommandWithProjections` and
`runDomainCommandWithCatalogProjections` invoke inline projections only for
accepted event pairs. A rejection or no-op has no append transaction in which
to perform a durable side effect. Do not put application effects in
`classifySilent` or `RunCommandOptions.beforeAppend`; `beforeAppend` is an
observation/test hook and may run for an accepted attempt that later conflicts.

## Result Ownership

An accepted domain outcome owns its returned event values until the caller
releases the result. Keiro shares the one typed `NonEmpty` batch used by the
attempt rather than copying it, and silent results retain neither the hydrated
state nor `SilentCommandContext`. If only persistence metadata is needed, use
the legacy runner or release the domain outcome after applying
`forgetDomainDecision`.

## Error Handling

`CommandError` values:

- `HydrationDecodeFailed CodecError`: a stored event could not be decoded.
- `HydrationReplayFailed StreamVersion HydrationReplayReason`: replay stalled.
  The reason is `HydrationNoInvertingEdge`, `HydrationAmbiguousInversion`,
  `HydrationQueueMismatch`, or `HydrationTruncatedChain`.
- `HydrationGapDetected expected observed`: stream truncation hid an event not
  covered by the hydration snapshot.
- `CommandRejected`: no live edge matched the command. This is distinct from a
  typed `DomainRejected` produced by an explicitly selected silent edge.
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
