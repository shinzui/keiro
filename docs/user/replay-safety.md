# Replayability Safety

Keiro is an event-sourcing runtime: before a command is applied, the aggregate's
current state is rebuilt by replaying its stored events through a pure Keiki
state machine. A stream is replay-safe when every piece of command input that
changes state is also recoverable from the events the command emitted. If a
transition reads command data and updates registers or state without emitting an
event that carries that data, the live decision can differ from the decision
made after a restart, snapshot rebuild, or full event-log replay.

Keiro enforces this at the command boundary. Public command runners do not
accept a bare `EventStream`; they require a `ValidatedEventStream`. A
`ValidatedEventStream` can only be built by the validation constructors in
`Keiro.EventStream.Validate`, so an unchecked event-stream record cannot reach
`runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`,
`runCommandWithProjections`, process managers, or routers.

## The Guarantee

`mkEventStream` runs Keiki's default structural validation over the stream's
transducer and returns either warnings or a runnable value:

```haskell
mkEventStream
  :: (Bounded s, Enum s, Ord s, Show s)
  => Text
  -> EventStream (HsPred rs ci) rs s ci co
  -> Either [EventStreamWarning] (ValidatedEventStream (HsPred rs ci) rs s ci co)
```

The default check rejects:

- hidden input: a transition reads command input that is not represented in the
  emitted event stream;
- nondeterministic guards: more than one transition could match the same folded
  state and command;
- statically dead edges: a transition appears unreachable under the structural
  analysis;
- incoherent snapshot configuration: a snapshot policy is enabled but
  `stateCodec = Nothing`.

The check is pure and solver-free. It runs before the stream is used, not while
events are being appended. Once construction returns `Right validated`, command
runners can hydrate, decide, append, and snapshot with the validated stream.

## Recommended Wiring

Keep the raw record under a `...Def` name and expose the runnable value under the
ordinary stream name:

```haskell
type OrderEventStream =
  EventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

type ValidatedOrderEventStream =
  ValidatedEventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

orderEventStreamDef :: OrderEventStream
orderEventStreamDef =
  EventStream
    { transducer = orderTransducer
    , initialState = NotStarted
    , initialRegisters = RNil
    , eventCodec = orderCodec
    , resolveStreamName = Stream.streamName
    , snapshotPolicy = Never
    , stateCodec = Nothing
    }

orderEventStream :: ValidatedOrderEventStream
orderEventStream =
  case mkEventStream "order" orderEventStreamDef of
    Right stream -> stream
    Left warnings -> error ("order stream is not replay-safe: " <> show warnings)
```

Application startup code can handle `Left` explicitly and fail the process with a
clear diagnostic. Generated code and test fixtures may use
`mkEventStreamOrThrow` when a sibling test or harness proves validation stays
clean:

```haskell
orderEventStream :: ValidatedOrderEventStream
orderEventStream =
  mkEventStreamOrThrow "order" orderEventStreamDef
```

The typed stream handle still uses the raw `EventStream` type as its phantom tag:

```haskell
orderStream :: OrderId -> Stream OrderEventStream
orderStream orderId =
  stream ("order-" <> orderIdText orderId)
```

That means existing stream handles and `CommandResult (EventStream ...)` result
types keep their storage meaning. Only the value passed to a runner is the
validated wrapper.

## Using A Validated Stream

Command runners accept the validated value:

```haskell
submitOrder orderId command =
  runCommand
    defaultRunCommandOptions
    orderEventStream
    (orderStream orderId)
    command
```

The same rule applies to higher-level write-side APIs:

- `runCommandWithSql` and `runCommandWithSqlEvents`;
- `runCommandWithProjections`;
- `ProcessManager.eventStream` and `ProcessManager.targetEventStream`;
- `Router.targetEventStream`.

If a bare `EventStream` record is passed to one of those APIs, the program does
not type-check because the runner expects `ValidatedEventStream`.

## When Validation Fails

Validation returns labelled `EventStreamWarning` values. A hidden-input warning
usually means the aggregate changed internal state from command-only data without
emitting an event that contains enough information to replay that change.

The usual fix is to emit a domain event that records the state-changing facts.
For example, if `PlaceOrder` writes a `customerId` register, emit an
`OrderPlaced { customerId = ... }` event and replay that event into the same
register. Do not fix a hidden input by disabling the check; doing so weakens the
replayability guarantee.

`mkEventStreamWith` exists for rare cases where a non-hidden-input warning is
known to be benign and documented. Use it narrowly. In ordinary application code,
prefer `mkEventStream` with the default options.

## What Keiro Does Not Prove

Replayability safety is one part of operational correctness. Keiro still expects
application code to preserve these properties:

- command values should be deterministic data, not live reads from clocks,
  random generators, or external services inside the transducer;
- event codecs and upcasters must decode every stored event version you still
  need to replay;
- explicit event ids are still needed for externally retried command submissions
  and integration boundaries;
- async projections, inbox handlers, outbox publishers, and timer firing
  functions must remain idempotent because those workers are at-least-once;
- snapshots are an optimization only. A corrupt or incompatible snapshot falls
  back to full event replay, so replay from events must remain correct.

In short: `ValidatedEventStream` makes unsafe aggregate replay shape
unrepresentable at the command boundary. It does not replace codec tests,
idempotency keys, operational monitoring, or deterministic integration design.
