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
  }
```

`defaultRunCommandOptions` uses:

- `retryLimit = 3`;
- `pageSize = 256`;
- no caller-supplied event ids;
- no `beforeAppend` hook.

## Running A Command

```haskell
runCommand
  :: (IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci))
  => RunCommandOptions
  -> EventStream phi rs s ci co
  -> Stream (EventStream phi rs s ci co)
  -> ci
  -> Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
```

Use `runCommand` when the only write you need is the event append.

Use `runCommandWithSql` when you need one SQL continuation in the same
transaction as the append.

Use `runCommandWithSqlEvents` when that continuation needs the decoded output
events as well as the append result.

## Hydration

Hydration starts from a compatible snapshot if the event stream has a
`stateCodec`; otherwise it reads the stream from version 0.

Every recorded event is:

1. checked against the codec's `eventTypes`;
2. upcast to the current schema version if needed;
3. decoded to the domain event type;
4. replayed through `Keiki.applyEvent`.

The command fails if any step fails. Keiro intentionally does not skip bad
events.

## Decision

Keiro calls `Keiki.step` with the hydrated `(state, registers)` and the command.

Outcomes:

- `Nothing`: command rejected, returned as `CommandRejected`.
- `Just (_, _, Nothing)`: command accepted as a no-op.
- `Just (_, _, Just event)`: command accepted and one event will be appended.

The v1 command API appends at most one event per command because it follows the
current Keiki transducer output shape.

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

`runCommandWithSqlEvents` additionally passes produced domain events:

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
- `HydrationReplayFailed StreamVersion`: Keiki could not replay a stored event.
- `CommandRejected`: the transducer rejected the command.
- `EncodeFailed CodecError`: a produced event could not be encoded.
- `StoreFailed StoreError`: Kiroku returned a non-retryable store error.
- `RetryExhausted Int StoreError`: retries were exhausted on a conflict.

Treat hydration failures as data/schema incidents. Treat command rejection as a
domain outcome. Treat store failures as infrastructure or concurrency failures,
depending on the underlying `StoreError`.
