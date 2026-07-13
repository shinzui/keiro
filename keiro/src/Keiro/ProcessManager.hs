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
dispatches ack 'AckOk', transient store failures retry, deterministic failures
halt, and undecodable messages follow the configured 'PoisonPolicy'.
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
    WorkerOptions (..),
    defaultWorkerOptions,
    isTransientStoreError,
    isTransientCommandError,
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
import Keiro.Command (CommandError (..), CommandResult, RunCommandOptions, runCommandWithSql)
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Prelude
import Keiro.Projection (InlineProjection, runCommandWithProjections)
import Keiro.Stream (Stream)
import Keiro.Telemetry (KeiroMetrics, recordDispatchDuplicate, recordDispatchFailed, recordDispatchPoison)
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
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import Prelude (any, filter, fromIntegral, length, not, uncurry, zip, (+))

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
    | {- | The command failed; the worker classifies the error. Transient store
      failures retry the source event, while deterministic failures halt.
      -}
      PMCommandFailed !CommandError
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

-- | Worker-level knobs shared by the process-manager and router workers.
data WorkerOptions es msg = WorkerOptions
    { poisonPolicy :: !(PoisonPolicy es msg)
    , transientRetryDelay :: !RetryDelay
    , metrics :: !(Maybe KeiroMetrics)
    }
    deriving stock (Generic)

defaultWorkerOptions :: WorkerOptions es msg
defaultWorkerOptions =
    WorkerOptions
        { poisonPolicy = PoisonHalt
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
    CommandRejected -> False
    EncodeFailed{} -> False

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
                        pure $ if benign then PMCommandDuplicate commandId else PMCommandFailed err

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

{- | Run a process manager as a live subscription draining a Shibuya adapter with
'defaultWorkerOptions'.

Use 'runProcessManagerWorkerWith' to override poison-message handling, transient
retry delay, or dispatch metrics. Every ingested message's ack handle is
finalized exactly once. Successful and duplicate dispatches finalize 'AckOk';
transient store failures finalize 'AckRetry'; deterministic failures finalize
'AckHalt'; undecodable messages follow the configured 'PoisonPolicy'.
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
                outcome <- tryError @StoreError (runProcessManagerOnce options manager recorded input)
                case outcome of
                    Left (_, storeErr) -> do
                        recordDispatchFailed (workerOptions ^. #metrics) 1
                        pure (ackForThrownStoreError (workerOptions ^. #transientRetryDelay) storeErr)
                    Right (Left err) -> do
                        recordDispatchFailed (workerOptions ^. #metrics) 1
                        pure (ackForCommandError (workerOptions ^. #transientRetryDelay) err)
                    Right (Right result) ->
                        ackForResults workerOptions (result ^. #managerResult) (result ^. #commandResults)
        finalizeAck decision
        pure decision

ackForThrownStoreError :: RetryDelay -> StoreError -> AckDecision
ackForThrownStoreError delay = ackForCommandError delay . StoreFailed

ackForResults ::
    (IOE :> es) =>
    WorkerOptions es msg ->
    PMStateResult managerTarget ->
    [PMCommandResult commandTarget] ->
    Eff es AckDecision
ackForResults workerOptions managerResult commandResults = do
    let duplicateCount = stateDuplicateCount managerResult + commandDuplicateCount commandResults
        failures = [err | PMCommandFailed err <- commandResults]
    recordDispatchDuplicate (workerOptions ^. #metrics) duplicateCount
    recordDispatchFailed (workerOptions ^. #metrics) (fromIntegral (length failures))
    pure $ case failures of
        [] -> AckOk
        errs
            | any (not . isTransientCommandError) errs ->
                AckHalt (HaltFatal (Text.pack (show (headDeterministic errs))))
            | otherwise ->
                AckRetry (workerOptions ^. #transientRetryDelay)

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

headDeterministic :: [CommandError] -> CommandError
headDeterministic errs =
    case filter (not . isTransientCommandError) errs of
        err : _ -> err
        [] -> case errs of
            err : _ -> err
            [] -> CommandRejected

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
