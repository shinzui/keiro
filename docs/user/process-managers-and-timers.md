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
    , eventStream :: EventStream phi rs s ci co
    , streamFor :: Text -> Stream (EventStream phi rs s ci co)
    , targetEventStream :: EventStream targetPhi targetRs targetState targetCi targetCo
    , handle :: input -> ProcessManagerAction ci targetCi
    }
```

The manager has its own event stream and may emit commands to one target event
stream type.

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

## Snapshotting Manager State

A long-running process manager accumulates events on its own `pm:<name>-<correlation>`
state stream. To keep hydration fast, give the manager's `eventStream` a snapshot policy
and a state codec — the same two fields you set on any aggregate `EventStream`:

```haskell
managerEventStream =
  baseManagerEventStream
    { snapshotPolicy = Every 100
    , stateCodec = Just (defaultStateCodec @ManagerRegs @ManagerState 1)
    }
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

## Firing Timers

`runTimerWorker` claims one due timer, calls your firing function, and marks the
timer fired if your function returns an event id. Its first argument is an opt-in
`Maybe KeiroMetrics` handle (pass `Nothing` to record no metrics):

```haskell
runTimerWorker Nothing now $ \timer -> do
  -- append or submit the timer command here
  pure (Just firedEventId)
```

To cap retries, use `runTimerWorkerWith (TimerWorkerOptions { maxAttempts = Just n })`:
a claimed timer whose post-claim `attempts` exceeds `n` is dead-lettered to the terminal
`Dead` state instead of fired.

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
