# Snapshots

Snapshots speed up hydration by storing an encoded `(state, registers)` seed for
a stream. They are advisory: if a snapshot is missing, incompatible, corrupt, or
too old, Keiro falls back to full replay.

## Enable The Schema

The `keiro_snapshots` table is created by `keiro-migrate`; see
[Database Migrations](migrations.md). Tests get it from the migrated template
database (the `keiro-test-support` `withMigratedSuite` fixture).

## Configure An EventStream

Snapshots are enabled by setting both:

- `snapshotPolicy`;
- `stateCodec`.

```haskell
eventStreamDef = EventStream
  { ...
  , snapshotPolicy = Every 100
  , stateCodec = Just stateCodec
  }

eventStream =
  mkEventStreamOrThrow "orders" eventStreamDef
```

If `stateCodec = Nothing`, hydration ignores snapshots even when the policy is
not `Never`; `mkEventStream` also reports that incoherent configuration as a
validation warning instead of producing a `ValidatedEventStream`.

See [Snapshots And Hydration](../guides/snapshots-and-hydration.md) for the
`jitsurei` snapshot-enabled order stream and its PostgreSQL-backed snapshot
test.

## SnapshotPolicy

```haskell
data SnapshotPolicy state
  = Never
  | Every Int
  | OnTerminal
  | Custom (state -> StreamVersion -> Bool)
```

Use:

- `Never` for small streams or early development.
- `Every n` for long-lived streams with predictable growth.
- `OnTerminal` when terminal aggregates are read often after closure.
- `Custom` when snapshot cadence depends on state or stream version.

Intervals less than or equal to zero never snapshot.

## Long-Running Process Managers

A process manager has its own state event stream (`ProcessManager.eventStream`). That
stream is an ordinary `EventStream`, so it snapshots exactly like any other: set
`snapshotPolicy` and `stateCodec` on the manager's `eventStream` and `runProcessManagerOnce`
writes and reuses snapshots through the same command path as `runCommand`. No extra wiring
is required.

Choose a policy by how the manager's state stream grows and ends:

- `Every n` — the default choice for a manager that reacts many times over its lifetime
  (a long-running saga). Pick `n` so a snapshot covers most of the history a reaction
  would otherwise replay; a few tens to a few hundreds is typical.
- `OnTerminal` — for a manager that is read again after it finishes (for example to
  answer "what did this workflow decide?") but rarely advances after closure.
- `Custom` — when snapshot cadence should depend on the folded state (for example,
  snapshot only once the manager has entered an active phase) or on the stream version.
- `Never` — for short-lived managers whose state stream stays small; replaying a handful
  of events is cheaper than maintaining snapshots.

Snapshots remain advisory for managers exactly as for aggregates: a missing, corrupt, or
shape-incompatible snapshot falls back to full replay of the manager state stream, and a
stored manager-event decode failure still fails the reaction. When you change the
manager's register-file or state shape, the `shapeHash` changes automatically (with
`defaultStateCodec`) and older snapshots are ignored safely; bump `stateCodecVersion`
yourself for an encoding change the shape hash does not capture.

The keiro test suite proves this end to end in
`keiro/test/Main.hs` under `describe "Keiro.ProcessManager snapshots"`: a manager with
`snapshotPolicy = Every 2` writes a snapshot of its `pm:` state stream at version 2, and a
later reaction hydrates from that snapshot and lands on top of it.

## StateCodec

```haskell
data StateCodec state = StateCodec
  { stateCodecVersion :: Int
  , shapeHash :: Text
  , encode :: state -> Value
  , decode :: Value -> Either Text state
  }
```

For an `EventStream`, the state codec encodes `(s, RegFile rs)`.

`shapeHash` must change when the register-file or state shape changes in a way
that makes old snapshots unsafe. A mismatched `shapeHash` causes Keiro to ignore
the snapshot and replay from the beginning.

## Hydration Behavior

During `runCommand`, Keiro:

1. looks up a snapshot by stream id, `stateCodec.stateCodecVersion`, and
   `stateCodec.shapeHash`;
2. decodes the snapshot state;
3. replays events after the snapshot stream version;
4. falls back to full replay if the snapshot path fails.

Snapshot decode failure is not a command failure. Stored event decode or replay
failure still is.

## Writing Snapshots

After a successful append, Keiro applies the newly produced events to the
hydrated state and writes a snapshot when `snapshotPolicy` says to do so.

Snapshots are keyed by stream id. A newer snapshot replaces an older one. An
older snapshot write cannot overwrite a newer row.

## Operational Guidance

- Snapshots are an optimization, not a source of truth.
- Keep snapshot codecs simple and deterministic.
- Treat snapshot schema changes as deploy-time compatibility work.
- Prefer full replay correctness over clever snapshot recovery.
- Monitor hydration latency before adding snapshot complexity.

Stream truncation is the exception to ordinary advisory fallback: once older
events are hidden, a valid snapshot must cover the hidden prefix. Before moving
a Kiroku truncation marker, follow the snapshot-first workflow in
[Stream Truncation](operations.md#stream-truncation). Keiro uses snapshot table
rows and their recorded stream versions for this coverage check; it does not
use Kiroku's snapshot-event convention.
