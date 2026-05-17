# Process Managers And Timers

Process managers coordinate work across streams. Timers provide durable
time-based wakeups for those managers.

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

Before appending, Keiro checks whether the deterministic event id is already in
the manager or target stream. Duplicate delivery returns duplicate results
rather than appending again.

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

If decoding fails, the worker returns `AckHalt`. If manager execution fails, it
also halts with the rendered command error.

## Timer Schema

Run:

```haskell
initializeTimerSchema
```

This creates `keiro_timers` and a due-timer index.

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
timer fired if your function returns an event id:

```haskell
runTimerWorker now $ \timer -> do
  -- append or submit the timer command here
  pure (Just firedEventId)
```

The low-level pieces are also available:

- `claimDueTimer`;
- `markTimerFired`;
- `scheduleTimerTx`.

## Timer Semantics

`claimDueTimer` uses `FOR UPDATE SKIP LOCKED`, so multiple workers can poll
without claiming the same row concurrently.

If the firing function returns `Nothing`, the row remains in `Firing`. Production
systems should decide how to recover stuck firing timers, for example through an
operator repair job or a future retry policy.
