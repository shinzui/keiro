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
with `stateCodec = Nothing`) from becoming a runnable stream.

The snapshot test initializes `keiro_snapshots`, runs `PlaceOrder` and
`ApprovePayment` through `snapshotOrderEventStream`, then queries the snapshot
row and expects stream version 2. See
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).

Use snapshots when measurement shows hydration latency matters. Do not enable
them as a substitute for event-log correctness, and version snapshot codecs as
carefully as event codecs.
