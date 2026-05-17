# Core Concepts

## Event Store

Keiro stores events through Kiroku. Kiroku owns append-only streams, stream
versions, global positions, subscriptions, and PostgreSQL storage. Keiro builds
typed application-level contracts on top of that store.

## Stream

`Stream a` wraps a Kiroku `StreamName`.

```haskell
newtype Stream a = Stream { name :: StreamName }
```

The `a` parameter gives streams a domain type. The stored stream name is still
plain text, but Haskell code can distinguish an order stream from an invoice
stream.

Use:

- `stream :: Text -> Stream a` to construct a stream.
- `streamName :: Stream a -> StreamName` to pass it to Kiroku or Keiro
  internals.
- `mapStreamName` when deriving related stream names.

## Codec

`Codec e` controls how events cross the storage boundary:

- `eventTypes` is the finite registry of legal stored event type tags.
- `eventType` selects the tag for a value.
- `schemaVersion` is the current event payload version.
- `encode` writes a JSON payload.
- `decode` reads the current JSON payload.
- `upcasters` migrate older payloads to the current shape.

Unknown event type tags are fatal during hydration. Decode failures are also
fatal for the command path because Keiro cannot safely decide from a partial
history.

## EventStream

`EventStream phi rs s ci co` is the aggregate contract.

- `phi` is the Keiki symbolic predicate carrier.
- `rs` is the register-file shape.
- `s` is aggregate state.
- `ci` is the command/input type.
- `co` is the output event type.

The contract includes:

- the Keiki `SymTransducer`;
- initial state and registers;
- an event `Codec`;
- `resolveStreamName`, a typed stream-to-Kiroku-name function;
- snapshot policy and optional state codec.

Applications usually define one `EventStream` per aggregate type and reuse it
everywhere commands are submitted.

## Command Cycle

The command cycle is:

1. Resolve the target stream name.
2. Hydrate state by reading stored events.
3. Decode every event with the stream codec.
4. Replay every event through the Keiki transducer.
5. Step the transducer with the new command.
6. Encode produced events.
7. Append with optimistic concurrency.
8. Optionally write a snapshot.

If append sees a retryable concurrency conflict, Keiro rehydrates and tries the
command again up to `retryLimit`.

## Snapshots

Snapshots are advisory acceleration. They store an encoded `(state, registers)`
seed for a stream and version. Hydration can start from a compatible snapshot and
replay only the tail.

Snapshot failures fall back to full replay. They do not change command
correctness.

## Read Models

A `ReadModel q r` describes a queryable view:

- metadata name, version, and shape hash;
- underlying table name;
- subscription name for position waits;
- default consistency mode;
- a Hasql transaction that runs the query.

Keiro tracks metadata in `keiro_read_models` and refuses reads from stale or
non-live models.

## Projections

Inline projections run in the same transaction as a command append through
`runCommandWithProjections` or `runCommandWithSqlEvents`.

Async projections are represented by `AsyncProjection`. They are at-least-once
in v1. Write handlers must be idempotent, usually by storing the source event id
and using `INSERT ... ON CONFLICT DO NOTHING`.

## Process Managers

A process manager is itself event-sourced. It reacts to source events, advances
its own state stream, emits commands to target streams, and schedules timers.

Keiro derives deterministic event ids from:

- manager name;
- correlation id;
- source event id;
- emitted command index.

That makes repeated delivery idempotent.

## Timers

Timers are stored in `keiro_timers`. A timer worker claims one due timer using
`FOR UPDATE SKIP LOCKED`, calls application code to fire it, and marks it fired
if an event id is returned.

Timers are low-level durable scheduling primitives. Your process manager decides
what a timer means.
