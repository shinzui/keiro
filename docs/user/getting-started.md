---
type: Tutorial
title: Getting Started
description: Build a first Keiro integration from database setup through a command path.
docId: DOC-9
tags: [keiro, getting-started, tutorial]
generated:
  by: human:nadeem
  at: 2026-09-18T04:06:27Z
timestamp: 2026-10-27T21:15:00Z
---

# Getting Started

This page walks through the shape of a Keiro integration. It is intentionally
library-oriented: Keiro does not start a server or hide your application
runtime.

## Prerequisites

You need:

- GHC 9.12.4, as supplied by the repository Nix shell.
- PostgreSQL 18 for this checkout's test and expected-schema baseline. Kiroku
  also supplies `kiroku.uuidv7()` on PostgreSQL 17; the UUID generator alone
  does not impose an 18-only requirement. See [Database Requirements](operations.md#database-requirements).
- Kiroku and Keiro schemas applied in the target database. For production, run
  `keiro-migrate`; see [Database Migrations](migrations.md).
- Application code that runs `Effectful` with Kiroku's `Store` effect and
  `Error StoreError` where command execution can fail.

Keiro and its Keiki and Kiroku dependencies are published on Hackage. Depend
on the Keiro packages from one coordinated release (currently 0.22.0.0).
Keiki and Kiroku have their own version series:

```cabal
build-depends:
  keiro-core ^>=0.22.0.0,
  keiro ^>=0.22.0.0,
  keiro-migrations ^>=0.22.0.0
```

Add `keiro-pgmq ^>=0.22.0.0` for work queues and `keiro-dsl ^>=0.22.0.0` for
the typed-spec toolchain. `keiro-ops`, `keiro-ops-http`, and
`keiro-test-support` are published at the same Keiro version; add the ones your
application uses. Language 5 remains the stable DSL contract; Language 6 is
available in this release as a candidate.

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
orderCategory :: StreamCategory OrderEventStream
orderCategory = categoryUnsafe "order"

orderStream :: Stream OrderEventStream
orderStream = entityStream orderCategory "123"
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
    (entityStream orderCategory orderId)
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

Run `keiro-migrate up` before starting the application; see
[Database Migrations](migrations.md). Its native `pg-migrate` plan composes the
embedded Kiroku component before Keiro's component. There are no
in-application `CREATE TABLE` helpers to call. Test suites apply the same plan
to a template database via the `keiro-test-support` `withMigratedSuite`
fixture.

## Verify The Repository

From the Keiro repository:

```bash
nix develop -c z3 --version
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-test jitsurei-test --test-show-details=direct
nix develop -c just user-documentation-validate
```

`keiro-test` and `jitsurei-test` exercise the core paths and worked examples
against ephemeral PostgreSQL databases. For all DSL suites use
`nix develop -c cabal test keiro-dsl:tests`; the `:tests` target includes every
conformance suite. The full repository gate is `nix develop -c just verify`.
