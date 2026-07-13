{- | Stateful coordination across aggregates: the process manager (saga).

A 'ProcessManager' reacts to an incoming event by stepping its /own/ state
machine — a private \"manager\" event stream, keyed by a correlation id — and,
in the same turn, dispatching commands to /target/ aggregates and scheduling
timers. It is the stateful counterpart of "Keiro.Router": where a router
resolves targets from a read model and holds no state, a process manager
folds the events it has seen into durable manager state and decides what to
do next from that state.

Every write — the manager-state append, each dispatched command, each timer
— is keyed by a 'deterministicCommandId' derived from
@(name, correlation, source event id, emit index)@. The manager pre-checks
each id with 'eventAlreadyIn' and folds the store's duplicate rejection into
a benign 'PMCommandDuplicate' \/ 'PMStateDuplicate'. Replaying the same
source event therefore appends nothing new, which is what makes the worker
crash-safe under at-least-once delivery.

Use 'runProcessManagerOnce' to react to a single event, or
'runProcessManagerWorker' to run the manager as a live subscription over a
Shibuya adapter. Worker acks are finalized exactly once: successful and duplicate
dispatches ack 'AckOk', transient store failures retry, systemic deterministic
failures halt, rejection-class failures follow 'RejectedCommandPolicy', and
undecodable messages follow the configured 'PoisonPolicy'.

=== Rejected commands and saga history

'RejectedHalt' is the safe default: the subscription stops without advancing,
so an operator cannot miss the failure. 'RejectedDeadLetter' instead writes a
durable "Keiro.DeadLetter.DispatchDeadLetter" and acknowledges the source
event; 'RejectedSkip' acknowledges and records only the metric. Prefer making a
target command total in its Keiki transducer (for example, an explicit no-op
transition for a benign business rejection) so no policy escape hatch is
needed.

For a process manager, dead-lettering a target dispatch creates an important
history split: the manager's own state stream has recorded its reaction, but
the target command never applied. Keiro cannot append a generic correction to
the manager stream because an event unknown to the manager's transducer would
make that stream fail replay. If saga history must reflect the failure, model a
domain-specific @DispatchFailed@-style command and event in the manager and
drive it from 'Keiro.DeadLetter.listDispatchDeadLetters' through an operator
runbook or automation. Otherwise, the dead-letter row is the durable witness.
Manager-state rejection itself has no such split because no manager event was
appended; its record uses emit index @-1@.

=== Bounded retries and source-event dead letters

On a Kiroku-backed Shibuya adapter, a transient failure finalizes 'AckRetry',
but retries are bounded by the Kiroku subscription's @RetryPolicy@. Its
@retryMaxAttempts@ counts total deliveries and defaults to five. When the bound
is exhausted, Kiroku records the /source event/ in @kiroku.dead_letters@ with
structured reason kind @max_attempts_exceeded@ and atomically advances the
checkpoint. The manager will not see that event again unless an operator
replays it through @Keiro.DeadLetter.Replay@. Install
'Keiro.Telemetry.kirokuEventBridge' on Kiroku's @eventHandler@ to observe the
terminal transition.

The adapter's @KirokuAdapterConfig@ does not currently expose @retryPolicy@, so
that path uses Kiroku's default bound. The sharded path is configurable:
'Keiro.Subscription.Shard.Worker.runShardedSubscriptionGroupAck' forwards
'Keiro.Subscription.Shard.Worker.ShardedWorkerOptions.retryPolicy' into the
same Kiroku acknowledgement ladder. A shard handler that dispatches commands
can use 'decideForFailures' and 'isRejectionClass' to classify outcomes, then
map the decision to its existing @ShardAck@ reply.

=== Correlation, ordering, and transaction boundaries

Events from one originating stream retain that stream's append order. Kiroku
consumer groups hash the originating stream id to a stable member, so sharding
does not split one stream across readers. Events from /different/ streams that
'correlate' to the same manager instance have no business-order guarantee,
however. Their append transactions race for global positions and, under
sharding, the streams may be processed concurrently by different members. A
retry on one member does not stop another member from advancing.

For example, both @payment-ORD1@'s @PaymentCaptured@ and @shipment-ORD1@'s
@ShipmentAllocated@ may correlate to order @ORD1@. The manager must accept
@PaymentCaptured@ then @ShipmentAllocated@ /and/ the reverse, normally with
states that record one fact while waiting for the other. An unsharded Kiroku
subscription processes its observed global order serially, including retries,
but that order still reflects append timing rather than a domain sequence.

Rule of thumb: 'correlate' may join streams freely, but every such join must be
order-insensitive. When a strict sequence is required, enforce it in the
manager's own state machine — for example with an explicit no-op/waiting state
and a timer-driven retry, or a modeled rejection handled by the dead-letter
policy — never by assuming delivery order.

The persistence boundary is also intentionally smaller than one whole saga
reaction. A manager event and its timers commit together when the manager
command appends; a timer-only no-op reaction schedules its timers in a separate
transaction. Each target command and its inline projections then commit in
their own transaction. A crash or rejected target can therefore leave durable
manager history without every target write. Deterministic ids make source-event
replay fill the missing writes without duplicating completed ones; the rejected
command section above describes the case that is deliberately acknowledged
instead.
-}
module Keiro.ProcessManager (
    -- * Definition
    ProcessManager (..),
    ProcessManagerAction (..),
    PMCommand (..),

    -- * Results
    ProcessManagerResult (..),
    PMCommandResult (..),
    PMStateResult (..),

    -- * Running
    PoisonPolicy (..),
    RejectedCommandPolicy (..),
    DispatchFailure (..),
    WorkerOptions (..),
    defaultWorkerOptions,
    isTransientStoreError,
    isTransientCommandError,
    isRejectionClass,
    decideForFailures,
    ackForCommandError,
    runProcessManagerOnce,
    runProcessManagerWorkerWith,
    runProcessManagerWorker,

    -- * Idempotency primitives
    deterministicCommandId,
    eventAlreadyIn,
    confirmBenignDuplicate,
)
where

import Data.Coerce (coerce)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError (..), CommandResult, RunCommandOptions, commandErrorClass, runCommandWithSql)
import Keiro.DeadLetter (DispatchDeadLetter (..), DispatcherKind (..), recordDispatchDeadLetter)
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Prelude
import Keiro.Projection (InlineProjection, runCommandWithProjections)
import Keiro.Stream (Stream)
import Keiro.Telemetry (KeiroMetrics, recordDispatchDeadLettered, recordDispatchDuplicate, recordDispatchFailed, recordDispatchPoison)
import Keiro.Timer (TimerRequest, scheduleTimerTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (eventExistsInStream)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), RecordedEvent)
import Kiroku.Store.Types qualified as StoreTypes
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import Prelude (any, filter, fromIntegral, length, not, uncurry, zip, (&&), (+))

{- | A process manager wiring together a manager state machine and the target
aggregate it drives.

* 'name' — stable identity; part of every deterministic write id.
* 'correlate' — derives the correlation key for an input event, selecting
  which manager instance handles it.
* 'eventStream' — the manager's own 'EventStream'; its events record the
  saga's progress.
* 'streamFor' — maps a correlation key to the manager's 'Stream' handle.
* 'targetEventStream' — the aggregate that dispatched commands are sent to.
* 'targetProjections' — inline projections for the target aggregate, run in
  the same transaction as each dispatched command's append. Return @[]@ for
  append-only dispatch.
* 'handle' — the pure reaction: given an input event, produce the
  manager-state command, the target commands to dispatch, and any timers to
  schedule.
-}
data ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo = ProcessManager
    { name :: !Text
    , correlate :: !(input -> Text)
    , eventStream :: !(ValidatedEventStream phi rs s ci co)
    , streamFor :: !(Text -> Stream (EventStream phi rs s ci co))
    , targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState targetCi targetCo)
    , targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
    {- ^ Inline projections for the target aggregate, run in the same transaction
    as each dispatched command's append. Return @[]@ for append-only dispatch.
    -}
    , handle :: !(input -> ProcessManagerAction ci targetCi)
    }
    deriving stock (Generic)

{- | What a process manager decides to do for one input event: advance its own
state with 'command', dispatch zero or more target 'commands', and schedule
zero or more 'timers'. All three are applied atomically with crash-safe
idempotency by 'runProcessManagerOnce'.
-}
data ProcessManagerAction ci targetCi = ProcessManagerAction
    { command :: !ci
    , commands :: ![PMCommand targetCi]
    , timers :: ![TimerRequest]
    }
    deriving stock (Generic)

-- | A single command addressed to a specific target stream.
data PMCommand targetCi = PMCommand
    { target :: !(Stream targetCi)
    , command :: !targetCi
    }
    deriving stock (Generic, Eq, Show)

-- | Outcome of one dispatched target command.
data PMCommandResult target
    = -- | The command appended events (carries the 'CommandResult').
      PMCommandAppended !(CommandResult target)
    | {- | The command was already applied (idempotent replay); carries the
      deterministic id that already existed.
      -}
      PMCommandDuplicate !EventId
    | {- | The command failed in the named target stream; the worker classifies
      the error. Transient failures retry, rejection-class failures follow
      'RejectedCommandPolicy', and systemic deterministic failures halt.
      -}
      PMCommandFailed !StoreTypes.StreamName !CommandError
    deriving stock (Generic, Eq, Show)

{- | Outcome of the manager's own state append. Unlike 'PMCommandResult' there
is no failure case — a manager-state append that genuinely errors aborts the
whole reaction via an outer @Left@ 'CommandError'.
-}
data PMStateResult target
    = PMStateAppended !(CommandResult target)
    | PMStateDuplicate !EventId
    deriving stock (Generic, Eq, Show)

{- | The complete result of reacting to one event: how the manager state
advanced, the outcome of each dispatched command in order, and how many
timers were scheduled.
-}
data ProcessManagerResult managerTarget commandTarget = ProcessManagerResult
    { managerResult :: !(PMStateResult managerTarget)
    , commandResults :: ![PMCommandResult commandTarget]
    , timersScheduled :: !Int
    }
    deriving stock (Generic, Eq, Show)

-- | What a worker does with a message its decoder cannot parse.
data PoisonPolicy es msg
    = PoisonHalt
    | PoisonSkip !(Envelope msg -> Eff es ())
    | PoisonDeadLetter !(Envelope msg -> Eff es ())

-- | What a worker does when every failed dispatch is a rejection-class error.
data RejectedCommandPolicy
    = -- | Halt without acknowledging so the source event replays. This is the default.
      RejectedHalt
    | -- | Persist a durable dispatch dead letter and acknowledge the source event.
      RejectedDeadLetter
    | -- | Acknowledge and count the rejection without persisting a record.
      RejectedSkip
    deriving stock (Generic, Eq, Show)

-- | One failed dispatch with the target identity needed by worker policy.
data DispatchFailure = DispatchFailure
    { emitIndex :: !Int
    , targetStreamName :: !StoreTypes.StreamName
    , commandError :: !CommandError
    }
    deriving stock (Generic, Eq, Show)

-- | Worker-level knobs shared by the process-manager and router workers.
data WorkerOptions es msg = WorkerOptions
    { poisonPolicy :: !(PoisonPolicy es msg)
    , rejectedCommandPolicy :: !RejectedCommandPolicy
    , transientRetryDelay :: !RetryDelay
    , metrics :: !(Maybe KeiroMetrics)
    }
    deriving stock (Generic)

defaultWorkerOptions :: WorkerOptions es msg
defaultWorkerOptions =
    WorkerOptions
        { poisonPolicy = PoisonHalt
        , rejectedCommandPolicy = RejectedHalt
        , transientRetryDelay = RetryDelay 5
        , metrics = Nothing
        }

isTransientStoreError :: StoreError -> Bool
isTransientStoreError = \case
    ConnectionLost{} -> True
    PoolAcquisitionTimeout -> True
    ConnectionError{} -> True
    WrongExpectedVersion{} -> True
    StreamAlreadyExists{} -> True
    EmptyAppendBatch{} -> False
    StreamNotFound{} -> False
    ReservedStreamName{} -> False
    StreamNameTooLong{} -> False
    DuplicateEvent{} -> False
    EventAlreadyLinked{} -> False
    LinkSourceEventMissing{} -> False
    UnexpectedServerError{} -> False

isTransientCommandError :: CommandError -> Bool
isTransientCommandError = \case
    StoreFailed err -> isTransientStoreError err
    RetryExhausted _ err -> isTransientStoreError err
    ConflictFixpoint _ err -> isTransientStoreError err
    HydrationDecodeFailed{} -> False
    HydrationReplayFailed{} -> False
    HydrationGapDetected{} -> False
    CommandRejected -> False
    CommandAmbiguous{} -> False
    EncodeFailed{} -> False

-- | Whether a command error is a per-command rejection covered by worker policy.
isRejectionClass :: CommandError -> Bool
isRejectionClass = \case
    CommandRejected -> True
    CommandAmbiguous{} -> True
    _ -> False

{- | Classify a group of failed dispatches and choose one acknowledgement.

Systemic deterministic errors always halt. Any transient error retries the
whole source event. Only an all-rejection group reaches the configured
'RejectedCommandPolicy'. Dead-letter writes are idempotent under redelivery.
-}
decideForFailures ::
    (IOE :> es, Store :> es) =>
    WorkerOptions es msg ->
    DispatcherKind ->
    Text ->
    Text ->
    RecordedEvent ->
    Int ->
    [DispatchFailure] ->
    Eff es AckDecision
decideForFailures workerOptions dispatcherKind dispatcherName correlationId sourceEvent attemptCount failures =
    case filter isSystemicDeterministic failures of
        failure : _ -> pure (haltFor failure)
        []
            | any (isTransientCommandError . (^. #commandError)) failures ->
                pure (AckRetry (workerOptions ^. #transientRetryDelay))
            | otherwise ->
                case failures of
                    [] -> pure AckOk
                    _ -> decideRejected
  where
    isSystemicDeterministic failure =
        let err = failure ^. #commandError
         in not (isTransientCommandError err) && not (isRejectionClass err)

    haltFor failure =
        AckHalt (HaltFatal (Text.pack (show (failure ^. #commandError))))

    decideRejected =
        case workerOptions ^. #rejectedCommandPolicy of
            RejectedHalt -> pure (haltFor (headFailure failures))
            RejectedDeadLetter -> do
                traverse_ recordFailure failures
                recordHandled
                pure AckOk
            RejectedSkip -> do
                recordHandled
                pure AckOk

    recordHandled =
        recordDispatchDeadLettered
            (workerOptions ^. #metrics)
            (fromIntegral (length failures))

    recordFailure failure =
        let err = failure ^. #commandError
         in recordDispatchDeadLetter
                DispatchDeadLetter
                    { dispatcherKind = dispatcherKind
                    , dispatcherName = dispatcherName
                    , correlationId = correlationId
                    , sourceEventId = sourceEvent ^. #eventId
                    , sourceGlobalPosition = sourceEvent ^. #globalPosition
                    , emitIndex = failure ^. #emitIndex
                    , targetStreamName = failure ^. #targetStreamName
                    , errorClass = commandErrorClass err
                    , errorDetail = Text.pack (show err)
                    , attemptCount = max 1 attemptCount
                    }

    headFailure = \case
        failure : _ -> failure
        [] -> DispatchFailure (-1) (StoreTypes.StreamName "unknown") CommandRejected

ackForCommandError :: RetryDelay -> CommandError -> AckDecision
ackForCommandError delay err
    | isTransientCommandError err = AckRetry delay
    | otherwise = AckHalt (HaltFatal (Text.pack (show err)))

{- | Derive a stable, collision-resistant 'EventId' for a manager write from
@(manager name, correlation id, source event id, emit index)@ via a v5 UUID.

The same inputs always yield the same id, so a replayed source event
produces the same write ids and the store's uniqueness constraint collapses
the duplicate. The manager-state append uses an emit index of @-1@ to keep
it distinct from the dispatched commands (which start at @0@). This positional
index is sound because 'handle' is pure and therefore returns the same command
order for the same input. The effectful router uses
'Keiro.Router.deterministicRouterCommandId' instead, retaining this positional
id only as a transition probe for pre-upgrade router dispatches.
-}
deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
deterministicCommandId managerName correlationId sourceEventId emitIndex =
    EventId
        $ UUID.V5.generateNamed UUID.V5.namespaceURL
        $ fmap (fromIntegral . fromEnum)
        $ Text.unpack
        $ Text.intercalate
            ":"
            [ "keiro"
            , "process-manager"
            , managerName
            , correlationId
            , UUID.toText (eventIdToUuid sourceEventId)
            , Text.pack (show emitIndex)
            ]

{- | React to a single source event: advance the manager's state, dispatch
its target commands, and schedule its timers — each under a deterministic,
idempotent write id.

The manager-state append and its timers commit in one transaction; each
target command is then dispatched (with its inline projections) in its own.
A duplicate manager append short-circuits to 'PMStateDuplicate' but still
re-runs the dispatch loop, so a crash between the state append and a
command dispatch is recovered on replay. Returns @Left@ only when the
manager-state append fails for a non-duplicate reason; per-command failures
are reported inside 'commandResults'.
-}
runProcessManagerOnce ::
    forall input phi rs s ci co targetPhi targetRs targetState targetCi targetCo es.
    ( HasCallStack
    , IOE :> es
    , Store :> es
    , Error StoreError :> es
    , BoolAlg phi (RegFile rs, ci)
    , BoolAlg targetPhi (RegFile targetRs, targetCi)
    , Eq co
    , Eq targetCo
    ) =>
    RunCommandOptions ->
    ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo ->
    RecordedEvent ->
    input ->
    Eff es (Either CommandError (ProcessManagerResult (EventStream phi rs s ci co) (EventStream targetPhi targetRs targetState targetCi targetCo)))
runProcessManagerOnce options manager sourceEvent input = do
    let correlationId = (manager ^. #correlate) input
        action = (manager ^. #handle) input
        managerStream = (manager ^. #streamFor) correlationId
        managerEventId = deterministicCommandId (manager ^. #name) correlationId (sourceEvent ^. #eventId) (-1)
        managerOptions = options & #eventIds .~ [managerEventId]
        managerStreamName = ((unvalidated (manager ^. #eventStream)) ^. #resolveStreamName) managerStream
    managerAlreadyProcessed <- eventAlreadyIn options managerStreamName managerEventId
    if managerAlreadyProcessed
        then finish correlationId (PMStateDuplicate managerEventId) action
        else do
            managerOutcome <-
                runCommandWithSql
                    managerOptions
                    (manager ^. #eventStream)
                    managerStream
                    (action ^. #command)
                    (\_ -> traverse_ scheduleTimerTx (action ^. #timers))
            case managerOutcome of
                Left err -> do
                    benign <- confirmBenignDuplicate managerStreamName managerEventId err
                    if benign
                        then finish correlationId (PMStateDuplicate managerEventId) action
                        else pure (Left err)
                Right (managerResult, scheduledInAppend) -> do
                    -- No-op manager commands do not execute runCommandWithSql's callback,
                    -- so schedule timer-only reactions explicitly.
                    case scheduledInAppend of
                        Nothing -> runTransaction (traverse_ scheduleTimerTx (action ^. #timers))
                        Just () -> pure ()
                    finish correlationId (PMStateAppended managerResult) action
  where
    finish correlationId managerResult action = do
        commandResults <- dispatchCommands correlationId (sourceEvent ^. #eventId) (action ^. #commands)
        pure
            $ Right
                ProcessManagerResult
                    { managerResult = managerResult
                    , commandResults = commandResults
                    , timersScheduled = length (action ^. #timers)
                    }

    dispatchCommands correlationId sourceEventId commands =
        traverse
            (uncurry (dispatchCommand correlationId sourceEventId))
            (zip [0 ..] commands)

    dispatchCommand correlationId sourceEventId emitIndex command = do
        let commandId = deterministicCommandId (manager ^. #name) correlationId sourceEventId emitIndex
            targetOptions = options & #eventIds .~ [commandId]
            targetStream = retarget (command ^. #target)
            targetStreamName = ((unvalidated (manager ^. #targetEventStream)) ^. #resolveStreamName) targetStream
        commandAlreadyProcessed <- eventAlreadyIn options targetStreamName commandId
        if commandAlreadyProcessed
            then pure (PMCommandDuplicate commandId)
            else do
                outcome <-
                    runCommandWithProjections
                        targetOptions
                        (manager ^. #targetEventStream)
                        targetStream
                        (command ^. #command)
                        ((manager ^. #targetProjections) (command ^. #target))
                case outcome of
                    Right result -> pure (PMCommandAppended result)
                    Left err -> do
                        benign <- confirmBenignDuplicate targetStreamName commandId err
                        pure $ if benign then PMCommandDuplicate commandId else PMCommandFailed targetStreamName err

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

{- | Run a process manager as a live subscription draining a Shibuya adapter with
'defaultWorkerOptions'.

Use 'runProcessManagerWorkerWith' to override poison-message handling, rejected
command handling, transient retry delay, or dispatch metrics. Every ingested message's ack handle is
finalized exactly once. Successful and duplicate dispatches finalize 'AckOk';
transient store failures finalize 'AckRetry'; rejection-class failures follow
'RejectedCommandPolicy'; other deterministic failures finalize 'AckHalt';
undecodable messages follow the configured 'PoisonPolicy'. Under
'RejectedDeadLetter', see the module-level saga-history contract before opting
in. On a Kiroku-backed adapter, each 'AckRetry' redelivery is bounded by the
subscription @RetryPolicy@ (five total deliveries by default). Exhaustion
dead-letters the source event in @kiroku.dead_letters@ and advances the
checkpoint; @KirokuAdapterConfig@ does not currently expose that bound. Observe
the terminal event with 'Keiro.Telemetry.kirokuEventBridge' and replay it with
@Keiro.DeadLetter.Replay@ when appropriate.
-}
runProcessManagerWorker ::
    forall msg input phi rs s ci co targetPhi targetRs targetState targetCi targetCo es.
    ( HasCallStack
    , IOE :> es
    , Store :> es
    , Error StoreError :> es
    , BoolAlg phi (RegFile rs, ci)
    , BoolAlg targetPhi (RegFile targetRs, targetCi)
    , Eq co
    , Eq targetCo
    ) =>
    RunCommandOptions ->
    ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo ->
    Adapter es msg ->
    (msg -> Maybe (RecordedEvent, input)) ->
    Eff es ()
runProcessManagerWorker =
    runProcessManagerWorkerWith defaultWorkerOptions

runProcessManagerWorkerWith ::
    forall msg input phi rs s ci co targetPhi targetRs targetState targetCi targetCo es.
    ( HasCallStack
    , IOE :> es
    , Store :> es
    , Error StoreError :> es
    , BoolAlg phi (RegFile rs, ci)
    , BoolAlg targetPhi (RegFile targetRs, targetCi)
    , Eq co
    , Eq targetCo
    ) =>
    WorkerOptions es msg ->
    RunCommandOptions ->
    ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo ->
    Adapter es msg ->
    (msg -> Maybe (RecordedEvent, input)) ->
    Eff es ()
runProcessManagerWorkerWith workerOptions options manager Adapter{source = adapterSource} decodeMessage =
    Streamly.fold Fold.drain
        $ Streamly.mapM handleIngested adapterSource
  where
    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested{envelope = env@Envelope{payload = message}, ack = AckHandle finalizeAck} = do
        decision <- case decodeMessage message of
            Nothing -> decideForPoison workerOptions "process-manager worker could not decode message" env
            Just (recorded, input) -> do
                let correlationId = (manager ^. #correlate) input
                    managerStream = (manager ^. #streamFor) correlationId
                    managerStreamName = ((unvalidated (manager ^. #eventStream)) ^. #resolveStreamName) managerStream
                    attemptCount = envelopeAttemptCount env
                outcome <- tryError @StoreError (runProcessManagerOnce options manager recorded input)
                case outcome of
                    Left (_, storeErr) -> do
                        recordDispatchFailed (workerOptions ^. #metrics) 1
                        pure (ackForThrownStoreError (workerOptions ^. #transientRetryDelay) storeErr)
                    Right (Left err) -> do
                        recordDispatchFailed (workerOptions ^. #metrics) 1
                        decideForFailures
                            workerOptions
                            DispatcherProcessManager
                            (manager ^. #name)
                            correlationId
                            recorded
                            attemptCount
                            [DispatchFailure (-1) managerStreamName err]
                    Right (Right result) ->
                        ackForResults
                            workerOptions
                            (manager ^. #name)
                            correlationId
                            recorded
                            attemptCount
                            (result ^. #managerResult)
                            (result ^. #commandResults)
        finalizeAck decision
        pure decision

ackForThrownStoreError :: RetryDelay -> StoreError -> AckDecision
ackForThrownStoreError delay = ackForCommandError delay . StoreFailed

ackForResults ::
    (IOE :> es, Store :> es) =>
    WorkerOptions es msg ->
    Text ->
    Text ->
    RecordedEvent ->
    Int ->
    PMStateResult managerTarget ->
    [PMCommandResult commandTarget] ->
    Eff es AckDecision
ackForResults workerOptions managerName correlationId sourceEvent attemptCount managerResult commandResults = do
    let duplicateCount = stateDuplicateCount managerResult + commandDuplicateCount commandResults
        failures =
            [ DispatchFailure emitIndex targetStreamName err
            | (emitIndex, PMCommandFailed targetStreamName err) <- zip [0 ..] commandResults
            ]
    recordDispatchDuplicate (workerOptions ^. #metrics) duplicateCount
    recordDispatchFailed (workerOptions ^. #metrics) (fromIntegral (length failures))
    decideForFailures
        workerOptions
        DispatcherProcessManager
        managerName
        correlationId
        sourceEvent
        attemptCount
        failures

stateDuplicateCount :: PMStateResult target -> Int64
stateDuplicateCount = \case
    PMStateDuplicate{} -> 1
    PMStateAppended{} -> 0

commandDuplicateCount :: [PMCommandResult target] -> Int64
commandDuplicateCount =
    fromIntegral . length . filter isDuplicateResult
  where
    isDuplicateResult = \case
        PMCommandDuplicate{} -> True
        _ -> False

envelopeAttemptCount :: Envelope msg -> Int
envelopeAttemptCount env =
    case env ^. #attempt of
        Nothing -> 1
        Just (Attempt attempt) -> fromIntegral attempt + 1

decideForPoison ::
    (IOE :> es) =>
    WorkerOptions es msg ->
    Text ->
    Envelope msg ->
    Eff es AckDecision
decideForPoison workerOptions reason env = do
    recordDispatchPoison (workerOptions ^. #metrics) 1
    case workerOptions ^. #poisonPolicy of
        PoisonHalt -> pure (AckHalt (HaltFatal reason))
        PoisonSkip callback -> do
            callback env
            pure AckOk
        PoisonDeadLetter callback -> do
            callback env
            pure (AckDeadLetter (InvalidPayload reason))

eventIdToUuid :: EventId -> UUID.UUID
eventIdToUuid (EventId uuid) = uuid

{- | Check whether an event with the given id is already present in a live stream.
Used as the pre-dispatch idempotency guard so a
command that was already applied on a prior (possibly crashed) attempt is
recognized as a duplicate before re-running it.
-}
eventAlreadyIn ::
    (Store :> es) =>
    RunCommandOptions ->
    StoreTypes.StreamName ->
    EventId ->
    Eff es Bool
eventAlreadyIn _options streamName eventId =
    eventExistsInStream streamName eventId

{- | Decide whether a failed append is a benign duplicate of the write just
attempted: whether @ourId@ is genuinely present in @streamName@.

Kiroku's @DuplicateEvent@ carries 'Just' the colliding id only when
PostgreSQL's detail string parses ('Nothing' otherwise), and because the
store's event-id uniqueness is global, even a matching id does not prove the
event landed in our stream. A mismatched id is never ours; a matching or
missing id is confirmed against the target stream with a point lookup. Callers
fold 'True' into their duplicate result and surface 'False' as the original
failure.
-}
confirmBenignDuplicate ::
    (Store :> es) =>
    StoreTypes.StreamName ->
    EventId ->
    CommandError ->
    Eff es Bool
confirmBenignDuplicate streamName ourId = \case
    StoreFailed (DuplicateEvent (Just duplicateId))
        | duplicateId == ourId -> eventExistsInStream streamName ourId
    StoreFailed (DuplicateEvent Nothing) -> eventExistsInStream streamName ourId
    _ -> pure False
