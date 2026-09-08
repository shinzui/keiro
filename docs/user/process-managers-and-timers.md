---
type: Explanation
title: Process Managers And Timers
description: Explain event-sourced coordination, deterministic command IDs, and durable timer workers.
timestamp: 2026-09-08T02:26:00Z
docId: DOC-17
tags: [keiro, process-managers, timers, coordination]
generated:
  by: human:nadeem
  at: 2026-08-10T19:19:35Z
---

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

## Inspecting Parked Timers

The public `Keiro.Timer` module exposes additive reads (currently unreleased):

```haskell
lookupTimerInspection ::
  (Store :> es) => TimerId -> Eff es (Maybe TimerInspection)

findDeadTimers ::
  (Store :> es) => DeadTimerFilter -> DeadTimerPageRequest ->
  Eff es (Either DeadTimerReadError DeadTimerPage)
```

`TimerInspection` contains `timer :: TimerRow` and `lastError :: Maybe Text`.
The nested row retains the original ID, owner, correlation, due time, payload,
status, attempts, and fired event ID. Lookup supports every lifecycle state and
returns `Nothing` for a missing ID. NULL reasons are `Nothing`; empty reasons
are `Just ""`; all other text is preserved in full without parsing or trimming.
Existing `TimerRow`, `lookupTimer`, worker and recovery signatures are unchanged.
No migration is required.

`DeadTimerFilter` combines an optional exact `processManagerName` with a
`reason :: TimerReasonFilter`. `anyDeadTimer` selects every dead row. Reason
modes are `AnyTimerReason`, `ReasonAbsent`, `ReasonExact Text`, and
`ReasonPrefix Text`. Text matching is case-sensitive and literal, using
PostgreSQL's deterministic `C` collation. Percent, underscore, quotes and
backslash have no wildcard or SQL meaning. Empty prefix matches every non-NULL
reason, including empty text; only `ReasonAbsent` specifically selects NULL.

```haskell
findDeadTimers
  (DeadTimerFilter (Just "my-manager") (ReasonPrefix "deferred:"))
  (DeadTimerPageRequest 25 Nothing)
```

`DeadTimerPageRequest` has `pageSize :: Int` and
`afterTimerId :: Maybe TimerId`. Sizes outside 1 through 100 return
`Left (InvalidDeadTimerPageSize requestedSize)` before database access, without
clamping. Database failures use the same outer store error behavior as lookup.
`DeadTimerPage` contains `timers :: [TimerInspection]` and
`nextAfterTimerId :: Maybe TimerId`. Pass that continuation into the next
request with the same filters. Restart without a cursor after changing filters.

Pages use ascending database UUID order, not due-time order. The cursor is
exclusive and still works if its row disappears. At most one extra matching row
is fetched to determine whether continuation exists; an empty or exhausted page
has no continuation. The result bound does not bound database search cost or
promise an indexed reason search. Pages observe current eligibility independently:
newly eligible IDs above the cursor may appear, while IDs at or below it are not
revisited. Restart to discover those earlier entries; traversal is not a snapshot.

These operations only observe storage. They do not claim work, increment attempts,
clear reasons, change timestamps, or authorize execution. Dead rows remain outside
the due-worker queue. The application owns payload decoding, reason categories,
and fresh permission checks before rendering. Skip malformed payloads without
revealing their contents. Continue using the storage cursor even when permission
filtering empties an entire page, and recheck permissions on subsequent requests.
An owner filter is an ownership label, not a permission credential.

Preserve the full reason for any later guarded recovery preflight. A successful
read reserves nothing: the separate guarded-resume work in
[IR-36](../improvement-requests/support-atomic-guarded-dead-timer-resume.md) must
revalidate its own state, owner, and reason guards before execution.

## Resuming deliberately parked work

Use `Keiro.Timer` for foreground resume of a Dead timer. Before discovery and
periodically on foreground-only hosts, call `recoverExpiredTimerResumes`. Inspect
with `lookupTimerInspection` or `findDeadTimers`, decode the original payload,
classify its reason, recheck application authorization, and establish session
availability before claiming. Neither the owner label nor a stored reason grants
permission. Unavailable sessions, revoked permissions, malformed work, and ordinary
dead letters should fail this preflight without consuming attempts.

`claimDeadTimer (DeadTimerClaimRequest tid owner exactReason ceiling seconds)`
returns `Right (Just claim)` only when the row is Dead, its owner and non-NULL
reason match exactly, and attempts are strictly below the explicit total ceiling.
Empty text is a valid reason; NULL is not. Matching is case-sensitive and literal,
including Unicode, percent, underscore, and backslash. Missing IDs and all guard
refusals return the same `Right Nothing` without changing any persisted column.
A ceiling of zero refuses every claim; negative ceilings and lease seconds outside
1–2147483647 return configuration errors before database access.

The successful claim preserves timer identity, original payload and due time,
retains the reason, increments attempts once, and returns an opaque ownership
handle. Execute work only after this success, outside the storage transaction.
`resumeClaimTimer` provides the claimed row. `resumeClaimLeaseUntil` is a claim-time
snapshot, not the current deadline after renewal. Schedule `renewTimerResume claim
seconds` while work runs according to your requested interval. Renewal uses database
time and cannot revive expired ownership.

Complete with `completeTimerResume claim eventId`. After stopping work on transient
failure or session loss, use `parkTimerResume claim`; it preserves the reason and
incremented history. Explicit abandonment uses `cancelTimerResume claim`. These
operations return False if ownership has expired or been replaced. On False,
cancel local work where possible and do not report successful timer completion.
Even immediate post-claim session loss has consumed an attempt. Leave work parked
at its ceiling; any higher ceiling is an explicit caller policy decision.

After a crash, expiry recovery returns guarded Firing rows directly to Dead,
clearing ownership without changing attempts or the original reason. It never
exposes that work to the due poller. Every ordinary worker pass also runs this
recovery, even with `requeueStuckAfter = Nothing`; that option controls only ordinary
token-free claims. Foreground re-parks do not increment the ordinary requeued
metric. Existing ID-only mark-fired, cancel, dead-letter, and requeue operations
refuse guarded claims, including expired claims awaiting recovery.

The guarantee is one currently valid storage owner. A lease cannot stop an external
call already running at expiry. Derive a stable idempotency key from the original
work identity and deduplicate durable results in the consumer; this is at-least-once
external execution. An ambiguous claim response requires inspection/recovery,
not assuming ownership.

Drain or stop old timer-mutating binaries, apply migrations, deploy all upgraded
writers, then enable foreground resume. Old binaries lack the token guards, so
mixed-version timer writers are unsafe despite the additive columns. Before
rollback, disable resume and drain or recover all guarded claims before starting
an older writer. Existing `TimerRow`, `TimerInspection`, worker callback, and
ID-only API signatures remain source-compatible.
