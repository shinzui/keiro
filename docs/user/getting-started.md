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
import Keiki.Core (HsPred)
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
raw `EventStream` type. The value passed to command runners is a
`ValidatedEventStream`; the stream handle's phantom tag remains the raw
`EventStream`.

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
codec, stream naming function, and optional snapshot codec. Keep the raw record
under a `...Def` name, then expose a validated value for command execution:

```haskell
type OrderEventStream =
  EventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

type ValidatedOrderEventStream =
  ValidatedEventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

orderEventStreamDef :: OrderEventStream
orderEventStreamDef = EventStream
  { transducer = orderTransducer
  , initialState = initialOrderState
  , initialRegisters = initialOrderRegisters
  , eventCodec = orderCodec
  , resolveStreamName = streamName
  , snapshotPolicy = Never
  , stateCodec = Nothing
  }

orderEventStream :: ValidatedOrderEventStream
orderEventStream =
  mkEventStreamOrThrow "order" orderEventStreamDef
```

When snapshots are enabled, set `snapshotPolicy` and `stateCodec`; see
[Snapshots](snapshots.md). For hand-written application startup code, prefer
`mkEventStream` when you want to handle validation warnings explicitly instead
of throwing. See [Replayability Safety](replay-safety.md).

## Run A Command

`runCommand` loads the stream, decodes and replays prior events through Keiki,
decides the command, encodes the produced event list, and appends that list with
optimistic concurrency.

```haskell
submitOrder orderId command =
  runCommand
    defaultRunCommandOptions
    orderEventStream
    (stream ("order-" <> orderId))
    command
```

The result carries the final stream version, optional global position, and the
number of events appended. A command may produce zero, one, or many events. A
command that produces no event returns a successful result with
`eventsAppended = 0`.

For the same flow in a complete package, see
[Build The Command Side](../guides/build-the-command-side.md). The source lives
in `jitsurei/src/Jitsurei/OrderStream.hs` and the command tests live in
`jitsurei/test/Main.hs`.

## Initialize Keiro Tables

Run `keiro-migrate` before starting the application; see
[Database Migrations](migrations.md). The codd migrations in `keiro-migrations`
are the single source of Keiro's framework schema — there are no in-application
`CREATE TABLE` helpers to call. Test suites apply the same migrations to a
template database via the `keiro-test-support` `withMigratedSuite` fixture.

## Verify The Repository

From the Keiro repository:

```bash
cabal build all
cabal test keiro-test
```

`keiro-test` exercises the core paths against an ephemeral PostgreSQL database.
