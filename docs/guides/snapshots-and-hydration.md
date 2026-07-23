# Snapshots And Hydration

Hydration is the work Keiro does before deciding a command: read stored events,
decode them, and replay them through the Keiki transducer to reconstruct current
state. For long streams, replaying from the beginning on every command can
become expensive. Snapshots store an encoded `(state, registers)` seed so Keiro
can replay only the tail.

`jitsurei` exposes two order event streams in
[`../../jitsurei/src/Jitsurei/OrderStream.hs`](../../jitsurei/src/Jitsurei/OrderStream.hs):

```haskell
orderEventStream :: ValidatedOrderEventStream
snapshotOrderEventStream :: ValidatedOrderEventStream
```

The normal stream has `snapshotPolicy = Never` and `stateCodec = Nothing`. The
snapshot-enabled raw definition changes only those fields before being
validated:

```haskell
snapshotOrderEventStreamDef :: OrderEventStream
snapshotOrderEventStreamDef =
  orderEventStreamDef
    { snapshotPolicy = Every 2
    , stateCodec = Just (defaultStateCodec @OrderRegs @OrderState 1)
    }

snapshotOrderEventStream :: ValidatedOrderEventStream
snapshotOrderEventStream =
  mkEventStreamOrThrow "jitsurei-order-snapshot" snapshotOrderEventStreamDef
```

`Every 2` writes a snapshot after appends that land on stream versions divisible
by two. The default state codec serializes the Haskell state and the Keiki
register file. This example uses an empty register file, but the shape hash is
still part of the snapshot lookup so incompatible register/state shapes are
ignored safely.

Snapshots are advisory. If the row is missing, corrupt, or shape-incompatible,
Keiro falls back to full replay. Stored event decode failures still fail the
command because the event log is the source of truth. `mkEventStreamOrThrow`
also prevents an incoherent snapshot configuration (`snapshotPolicy` enabled
with `stateCodec = Nothing`) from becoming a runnable stream, and rejects a
codec that cannot encode its initial state and registers. Post-append encode or
store failures are swallowed so they cannot reverse an already-committed
command or workflow journal append.

The snapshot metrics distinguish these paths:

- `keiro.snapshot.read.hits` counts usable hydration seeds.
- `keiro.snapshot.read.misses` counts full-replay fallbacks, including a fresh
  stream with no snapshot yet.
- `keiro.snapshot.decode.failures` counts matching rows whose JSON cannot be
  decoded.
- `keiro.snapshot.encode.failures` counts post-commit encodes that raised an
  `ErrorCall` and were skipped.
- `keiro.snapshot.write.failures` counts post-commit store writes that failed
  and were skipped.
- `keiro.snapshot.seed.divergence` counts sampled compatible snapshot seeds
  whose canonical encoded state disagrees with a full replay through the same
  stream version. Alert on any non-zero value.

Command hydration samples one in 1000 usable seeds by default. The check runs
asynchronously, is read-only, and emits a structured log with the stream, seed
version, and seeded/full SHA-256 digests when it finds a mismatch. Configure
`RunCommandOptions.seedVerifySampleRate`; `1` verifies every snapshot hit and
`0` disables the witness.

The snapshot test initializes `keiro_snapshots`, runs `PlaceOrder` and
`ApprovePayment` through `snapshotOrderEventStream`, then queries the snapshot
row and expects stream version 2. See
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).

Use snapshots when measurement shows hydration latency matters. Do not enable
them as a substitute for event-log correctness, and version snapshot codecs as
carefully as event codecs.

## The one write that can replace a newer snapshot

Keiro rejects an older snapshot write when the stored row uses the same codec
version and register-file shape hash. If either discriminant differs, however,
the incoming write replaces the row even when it describes a lower stream
version. This escape hatch is intentional: after a codec rollback, the older
deployment must be able to reclaim the snapshot slot instead of missing a
newer, incompatible row forever.

Because there is one snapshot row per stream, two live deployments with
different codec versions or shape hashes can overwrite that row back and
forth. Each side then misses snapshots written by the other and pays for full
replay. Avoid prolonged mixed-codec deployments; the behavior is a performance
cost, not a correctness risk, because hydration always falls back to the event
log.

## Upgrading Keiki: expect a one-time full replay

Keiki EP-78 stabilizes the register-file shape-hash calculation. When upgrading
from a Keiki version with the earlier hash, existing snapshot rows no longer
match the recomputed `regfile_shape_hash`. Keiro deliberately does not
compensate for that change: Keiki owns the hash, and an incompatible snapshot
is handled as an ordinary advisory miss.

Expect `keiro.snapshot.read.misses` to spike while each affected stream pays a
full replay. Its snapshot row repopulates the next time the configured policy
fires after an append, after which hydration hits again. No event or aggregate
state migration is required.
