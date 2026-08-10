# Process Managers And Timers

Process managers coordinate work across streams. Timers provide durable
time-based wakeups for those managers.

A process manager computes its targets *purely* from its own state via `handle`.
When target resolution must run *effectfully* — for example by querying a read
model — use the stateless `Keiro.Router` instead; it reuses the same `PMCommand`
dispatch and exactly-once-per-target idempotency. See
[Routers And Effectful Fan-out](../guides/routers-and-effectful-fan-out.md).

## Process Manager Shape

```haskell
data ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo =
  ProcessManager
    { name :: Text
    , correlate :: input -> Text
    , eventStream :: ValidatedEventStream phi rs s ci co
    , streamFor :: Text -> Stream (EventStream phi rs s ci co)
    , targetEventStream :: ValidatedEventStream targetPhi targetRs targetState targetCi targetCo
    , targetProjections :: Stream targetCi -> [InlineProjection targetCo]
    , handle :: input -> ProcessManagerAction ci targetCi
    }
```

The manager has its own event stream and may emit commands to one target event
stream type.

For typed target decisions, use the additive `DomainProcessManager` shape. It
keeps the same manager state, correlation, timer, and action fields, but replaces
`targetEventStream` with a `targetHandler :: DomainCommandHandler ...`:

```haskell
data DomainProcessManager input phi rs state command event
    targetPhi targetRs targetState targetCommand targetEvent rejection noOp =
  DomainProcessManager
    { name :: Text
    , correlate :: input -> Text
    , eventStream :: ValidatedEventStream phi rs state command event
    , streamFor :: Text -> Stream (EventStream phi rs state command event)
    , targetHandler
        :: DomainCommandHandler
             targetPhi targetRs targetState targetCommand targetEvent rejection noOp
    , targetProjections :: Stream targetCommand -> [InlineProjection targetEvent]
    , handle :: input -> ProcessManagerAction command targetCommand
    }
```

The manager's own state transition remains on the established command path.
Only dispatched target commands return typed domain outcomes, so the existing
state-and-timer transaction boundary is unchanged.

`input` is the decoded source message your subscription worker gives to the
manager.

`streamFor` is where you choose the manager's stream family. Kiroku categories
come from the part of a stream name before the first `-`, so
`pm:fulfillment-order-1` is in category `pm:fulfillment`, while
`pm:counter-order-1` is in category `pm:counter`. Use the
`pm:<manager-name>-<correlation-id>` convention when each
workflow/process-manager type needs its own category subscription.

## Actions

```haskell
data ProcessManagerAction ci targetCi = ProcessManagerAction
  { command :: ci
  , commands :: [PMCommand targetCi]
  , timers :: [TimerRequest]
  }
```

The `command` advances the process manager's own state stream. `commands` are
target aggregate commands emitted after the manager state advances. `timers` are
scheduled transactionally with the manager state append.

## Idempotency

Process managers use deterministic event ids:

```haskell
deterministicCommandId
  :: Text
  -> Text
  -> EventId
  -> Int
  -> EventId
```

The id is derived from manager name, correlation id, source event id, and emit
index. Index `-1` is used for the manager state event; `0..` are used for target
commands.

Before appending, Keiro uses a point lookup to check whether the deterministic
event id is already in the manager or target stream. Duplicate delivery returns
duplicate results rather than appending again. If a concurrent worker wins the
race after the pre-check, the store's duplicate-id rejection is folded into the
same duplicate result.

For a domain-aware target, an accepted duplicate stays a distinct
`DomainPMCommandDuplicate EventId`. The event id proves the deterministic
accepted append already happened, but it cannot reconstruct the original
in-memory `NonEmpty` event values. Rejection and no-op append no event id, so
redelivery safely re-evaluates their pure classifier.

## Running Once

Use `runProcessManagerOnce` when you already have one recorded source event and
decoded input:

```haskell
runProcessManagerOnce
  defaultRunCommandOptions
  manager
  recordedEvent
  decodedInput
```

The result includes:

- manager state append or duplicate;
- one result per emitted target command;
- count of timers scheduled.

`runDomainProcessManagerOnce` returns the parallel
`DomainProcessManagerResult`. Every target entry is one of:

- `DomainPMCommandHandled outcome` for accepted, typed rejection, or typed
  no-op;
- `DomainPMCommandDuplicate eventId` for confirmed accepted redelivery;
- `DomainPMCommandFailed streamName commandError` for a genuine command
  failure.

This detailed one-shot result owns all returned accepted batches, so its live
memory is proportional to the payloads across the fan-out. Use it only when the
caller needs those details.

See [Process Managers And Timers](../guides/process-managers-and-timers.md) for
the `jitsurei` fulfillment manager, duplicate-delivery test, and TypeID-backed
timer fixture.

## Running As A Worker

`runProcessManagerWorker` consumes a Shibuya `Adapter` source:

```haskell
runProcessManagerWorker
  defaultRunCommandOptions
  manager
  adapter
  decodeMessage
```

`decodeMessage` must turn adapter messages into `(RecordedEvent, input)`.

`runProcessManagerWorker` uses `defaultWorkerOptions`. Use
`runProcessManagerWorkerWith` to override poison-message handling, transient
retry delay, or dispatch metrics. The worker finalizes each message's
`AckHandle` exactly once:

- successful and duplicate dispatches finalize `AckOk`;
- transient store failures finalize `AckRetry`;
- deterministic command failures finalize `AckHalt`;
- undecodable messages follow the configured `PoisonPolicy` (default:
  `PoisonHalt`).

`runDomainProcessManagerWorker` and
`runDomainProcessManagerWorkerWith` use the same adapter and policies. A typed
rejection/no-op is handled and finalizes `AckOk`; it does not enter
`RejectedCommandPolicy`, retry, or create a dead letter. `DomainPMCommandFailed`
still follows the established transient, systemic, rejection-class, and poison
policy.

Domain workers do not construct the detailed result list and discard it. They
strictly summarize each target into only duplicate count and failure identity,
then release its handled payload before dispatching the next target. Prefer the
worker/streamed path for high fan-out when only acknowledgement policy is
needed.

## Domain-Aware Routers

`DomainRouter` is the stateless counterpart: it replaces `Router`'s
`targetEventStream` with `targetHandler` and exposes
`runDomainRouterOnce`, `runDomainRouterWorkerWith`, and
`runDomainRouterWorker`. Resolution order, target-identity deterministic ids,
legacy positional-id duplicate compatibility, and one transaction per target
remain unchanged.

Its detailed `DomainRouterResult` uses the same handled, duplicate, and failed
target cases and therefore has the same proportional-memory contract. Router
workers use the same bounded strict summary and acknowledge typed rejection or
no-op normally.

## Snapshotting Manager State

A long-running process manager accumulates events on its own `pm:<name>-<correlation>`
state stream. To keep hydration fast, give the manager's raw event-stream
definition a snapshot policy and a state codec before validating it — the same
two fields you set on any aggregate `EventStream`:

```haskell
managerEventStreamDef =
  baseManagerEventStreamDef
    { snapshotPolicy = Every 100
    , stateCodec = Just (defaultStateCodec @ManagerRegs @ManagerState 1)
    }

managerEventStream =
  mkEventStreamOrThrow "fulfillment-manager" managerEventStreamDef
```

`runProcessManagerOnce` advances manager state through the ordinary command path, so it
writes and reuses these snapshots with no extra wiring. See
[Snapshots → Long-Running Process Managers](snapshots.md) for choosing the policy and the
codec-versioning caveats.

## Timer Schema

The `keiro_timers` table and its due-timer index are created by `keiro-migrate`;
see [Database Migrations](migrations.md). Tests get them from the migrated
template database (the `keiro-test-support` `withMigratedSuite` fixture).

## Scheduling Timers

A timer request is:

```haskell
data TimerRequest = TimerRequest
  { timerId :: TimerId
  , processManagerName :: Text
  , correlationId :: Text
  , fireAt :: UTCTime
  , payload :: Value
  }
```

Process managers schedule timers by returning them in `ProcessManagerAction`.
Keiro writes those timers in the same transaction as the manager state append.

Timer ids should be deterministic for replay-safe behavior.

Before deploying a process-manager or router fan-out change, drain its
redelivery window. Before scheduling a new timer payload shape, deploy every
firer that can decode both shapes. See
[Deploy Ordering](deploy-ordering.md#4-drain-process-manager-and-router-decide-changes).

## Firing Timers

`runTimerWorker` claims one due timer, calls your firing function, and marks the
timer fired if your function returns an event id. Its first argument is an opt-in
`Maybe KeiroMetrics` handle (pass `Nothing` to record no metrics):

```haskell
runTimerWorker Nothing now $ \timer -> do
  -- append or submit the timer command here
  pure (Just firedEventId)
```

For a production worker, validate a bounded retry and stale-claim policy once at
startup, then pass it together with the metrics handle:

```haskell
timerOptions =
  either (error . show) id $
    mkTimerWorkerOptions TimerWorkerOptions
      { maxAttempts = Just 5
      , requeueStuckAfter = Just 300
      }

runTimerWorkerWith (Just metrics) timerOptions now $ \timer -> do
  -- append or submit the idempotent timer command here
  pure (Just firedEventId)
```

A claimed timer whose post-claim `attempts` exceeds the ceiling is
dead-lettered to the terminal `Dead` state. Each pass also returns `Firing`
claims older than `requeueStuckAfter` to `Scheduled`; because that can repeat
the fire action, the handler must remain idempotent.

The low-level pieces are also available:

- `claimDueTimer`;
- `markTimerFired`;
- `scheduleTimerTx`.

## Timer Semantics

`claimDueTimer` uses `FOR UPDATE SKIP LOCKED`, so multiple workers can poll
without claiming the same row concurrently.

If the firing function returns `Nothing`, the row remains in `Firing`. Recover such rows
with the supported timer recovery API (`findStuckTimers`, `requeueStuckTimer`,
`cancelTimer`, `deadLetterTimer`); see the [stuck-row recovery runbook](operations.md) in
Operations.
