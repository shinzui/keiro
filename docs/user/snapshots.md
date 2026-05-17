# Snapshots

Snapshots speed up hydration by storing an encoded `(state, registers)` seed for
a stream. They are advisory: if a snapshot is missing, incompatible, corrupt, or
too old, Keiro falls back to full replay.

## Enable The Schema

For production, run `keiro-migrate`; see
[Database Migrations](migrations.md). For development and tests, run:

```haskell
initializeSnapshotSchema
```

This creates `keiro_snapshots`.

## Configure An EventStream

Snapshots are enabled by setting both:

- `snapshotPolicy`;
- `stateCodec`.

```haskell
eventStream = EventStream
  { ...
  , snapshotPolicy = Every 100
  , stateCodec = Just stateCodec
  }
```

If `stateCodec = Nothing`, hydration ignores snapshots even when the policy is
not `Never`.

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
