# Getting Started

This page walks through the shape of a Keiro integration. It is intentionally
library-oriented: Keiro does not start a server or hide your application
runtime.

## Prerequisites

You need:

- GHC 9.12.x.
- PostgreSQL 18 or newer. Kiroku's schema uses `uuidv7()`.
- Kiroku and Keiro schemas applied in the target database. For production, run
  `keiro-migrate`; see [Database Migrations](migrations.md).
- Application code that runs `Effectful` with Kiroku's `Store` effect and
  `Error StoreError` where command execution can fail.

The repository uses local sibling packages for unreleased dependencies:

```cabal
packages:
  .
  /path/to/keiki
  /path/to/keiki/keiki-codec-json
  /path/to/kiroku/kiroku-store
```

## Add Keiro To An Application

Import the broad core module for command-side code:

```haskell
import Keiro
import Keiro.Prelude
```

Import these modules explicitly when you use their surface:

```haskell
import Keiro.Projection
import Keiro.ProcessManager
import Keiro.ReadModel
import Keiro.Timer
```

## Define A Stream

`Stream a` is a typed wrapper around Kiroku's `StreamName`. The type parameter
prevents accidental stream mixups at compile time.

```haskell
orderStream :: Stream OrderEventStream
orderStream = stream "order-123"
```

For ordinary aggregates, the type parameter is usually the aggregate's
`EventStream` type.

## Define An Event Codec

A `Codec e` maps domain events to stored JSON payloads and back. It also names
the legal event type tags and current schema version.

```haskell
orderCodec :: Codec OrderEvent
orderCodec = Codec
  { eventTypes = "OrderPlaced" :| ["OrderCancelled"]
  , eventType = \case
      OrderPlaced{} -> "OrderPlaced"
      OrderCancelled{} -> "OrderCancelled"
  , schemaVersion = 1
  , encode = encodeOrderEvent
  , decode = decodeOrderEvent
  , upcasters = []
  }
```

`encodeForAppend` stores `schemaVersion` in event metadata. `decodeRecorded`
rejects unknown event types before decoding the payload.

## Define An Event Stream Contract

An `EventStream` combines your pure Keiki transducer, initial state, event
codec, stream naming function, and optional snapshot codec.

```haskell
orderEventStream :: EventStream phi rs OrderState OrderCommand OrderEvent
orderEventStream = EventStream
  { transducer = orderTransducer
  , initialState = initialOrderState
  , initialRegisters = initialOrderRegisters
  , eventCodec = orderCodec
  , streamName = streamName
  , snapshotPolicy = Never
  , stateCodec = Nothing
  }
```

When snapshots are enabled, set `snapshotPolicy` and `stateCodec`; see
[Snapshots](snapshots.md).

## Run A Command

`runCommand` loads the stream, decodes and replays prior events through Keiki,
decides the command, encodes new events, and appends them with optimistic
concurrency.

```haskell
submitOrder orderId command =
  runCommand
    defaultRunCommandOptions
    orderEventStream
    (stream ("order-" <> orderId))
    command
```

The result carries the final stream version, optional global position, and the
number of events appended. A command that produces no event returns a successful
result with `eventsAppended = 0`.

## Initialize Keiro Tables

For production, run `keiro-migrate` before starting the application. For local
development and tests, you can still initialize only the tables for features you
use:

```haskell
initializeKeiroTables :: (Store :> es) => Eff es ()
initializeKeiroTables = do
  initializeSnapshotSchema
  initializeReadModelSchema
  initializeTimerSchema
```

Each initializer uses `CREATE TABLE IF NOT EXISTS` and is safe for development
startup paths. It is not a production migration ledger.

## Verify The Repository

From the Keiro repository:

```bash
cabal build all
cabal test keiro-test
```

`keiro-test` exercises the core paths against an ephemeral PostgreSQL database.
