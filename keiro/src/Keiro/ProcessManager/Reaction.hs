-- | Additive process-manager reactions with explicit typed outcomes.
--
-- A reaction may advance a private saga stream, run timer SQL atomically with
-- that append, and then dispatch commands to independent target streams. The
-- timer and target phases are deliberately separate transactions. Accepted
-- redelivery validates the recorded saga witness, skips timer SQL, and retries
-- target fan-out with deterministic target-keyed ids.
module Keiro.ProcessManager.Reaction
  ( -- * Definition
    ReactiveProcessManager (..),
    ReactionPlan (..),
    FollowUp (..),
    ScheduleMode (..),

    -- * Results
    ReactionStateResult (..),
    ReactionTimerEffects (..),
    ReactionError (..),
    ReactiveProcessManagerResult (..),

    -- * Running
    runReactiveProcessManagerOnce,

    -- * Identity
    deterministicReactionCommandId,
  )
where

import Control.Monad (foldM)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Coerce (coerce)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Codec (decodeRecorded)
import Keiro.Command
  ( CommandError,
    DomainCommandHandler,
    DomainCommandOutcome (..),
    DomainDecision (..),
    RunCommandOptions,
    runDomainCommandWithSqlEvents,
  )
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Prelude
import Keiro.ProcessManager
  ( PMCommand (..),
    PMCommandResult (..),
    deterministicCommandIdProbes,
    dispatchDeduplicatedCommand,
    firstExistingEventId,
  )
import Keiro.Projection (InlineProjection, runCommandWithProjections)
import Keiro.Stream (Stream)
import Keiro.Timer
  ( TimerId,
    TimerRequest,
    cancelTimerTx,
    scheduleTimerOnceTx,
    scheduleTimerTx,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (getStream, readStreamForward)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), RecordedEvent, StreamName (..), StreamVersion (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

-- | A pure reaction selected from one decoded input.
--
-- 'NoAdvance' has no saga command and therefore cannot carry accepted-only
-- effects. 'AdvanceReaction' always runs @followUps@ for the observed outcome;
-- @onAccepted@ is added only when this invocation appends or recovers the
-- deterministic accepted witness.
data ReactionPlan ci targetCi
  = NoAdvance ![FollowUp targetCi]
  | AdvanceReaction
      { command :: !ci,
        followUps :: ![FollowUp targetCi],
        onAccepted :: ![FollowUp targetCi]
      }
  deriving stock (Generic, Eq, Show)

-- | One ordered reaction effect. Timer operations retain their relative order
-- in the timer transaction and dispatches retain theirs in the later target
-- phase; the two kinds are not one cross-stream transaction.
data FollowUp targetCi
  = FollowDispatch !(PMCommand targetCi)
  | FollowSchedule !ScheduleMode !TimerRequest
  | FollowCancel !TimerId
  deriving stock (Generic, Eq, Show)

-- | Whether scheduling may move an existing still-scheduled row or is strictly
-- insert-only while any row with the timer id exists.
data ScheduleMode = Rearm | Once
  deriving stock (Generic, Eq, Show)

-- | The saga-state portion of a reaction result.
data ReactionStateResult target co rejection noOp
  = ReactionNotAdvanced
  | ReactionEvaluated !(DomainCommandOutcome target co rejection noOp)
  | ReactionDuplicate !EventId
  deriving stock (Generic, Eq, Show)

-- | Honest accounting for the timer transaction that committed.
--
-- @statementsCommitted@ includes no-op statements. @onceInserted@ and
-- @timersCancelled@ count only rows actually changed. Rearm intentionally has
-- no changed-row counter because the underlying SQL does not return one.
data ReactionTimerEffects = ReactionTimerEffects
  { statementsCommitted :: !Int,
    onceInserted :: !Int,
    timersCancelled :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Reaction failures that are not infrastructure failures. Store errors stay
-- in the ambient @Error StoreError@ effect.
data ReactionError
  = ReactionCommandFailed !CommandError
  | ReactionWitnessMissing !StreamName !EventId
  | ReactionWitnessUndecodable !StreamName !EventId
  deriving stock (Generic, Eq, Show)

-- | Detailed result for a one-shot caller. Worker entry points use a strict
-- payload-free reduction instead of retaining this value through fan-out.
data ReactiveProcessManagerResult managerTarget co rejection noOp commandTarget = ReactiveProcessManagerResult
  { managerResult :: !(ReactionStateResult managerTarget co rejection noOp),
    commandResults :: ![PMCommandResult commandTarget],
    timerEffects :: !ReactionTimerEffects
  }
  deriving stock (Generic, Eq, Show)

-- | Runtime wiring for one reactive process manager.
data ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp = ReactiveProcessManager
  { name :: !Text,
    correlate :: !(input -> Text),
    sagaHandler :: !(DomainCommandHandler phi rs s ci co rejection noOp),
    streamFor :: !(Text -> Stream (EventStream phi rs s ci co)),
    targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState targetCi targetCo),
    targetProjections :: !(Stream targetCi -> [InlineProjection targetCo]),
    react :: !(input -> ReactionPlan ci targetCi)
  }
  deriving stock (Generic)

zeroTimerEffects :: ReactionTimerEffects
zeroTimerEffects = ReactionTimerEffects 0 0 0

-- | Run one reaction. Accepted saga events and their timer effects commit in
-- one transaction; target commands are then attempted independently in source
-- order. Duplicate accepted recovery validates the exact saga witness before
-- skipping timer SQL and retrying target dispatches.
runReactiveProcessManagerOnce ::
  forall input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg phi (RegFile rs, ci),
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq co,
    Eq targetCo
  ) =>
  RunCommandOptions ->
  ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp ->
  RecordedEvent ->
  input ->
  Eff
    es
    ( Either
        ReactionError
        ( ReactiveProcessManagerResult
            (EventStream phi rs s ci co)
            co
            rejection
            noOp
            (EventStream targetPhi targetRs targetState targetCi targetCo)
        )
    )
runReactiveProcessManagerOnce options manager sourceEvent input =
  case (manager ^. #react) input of
    NoAdvance unconditional -> do
      timers <- runTimerPhase unconditional
      commands <- dispatchReactionCommands options manager correlationId sourceId unconditional
      pure
        $ Right
          ReactiveProcessManagerResult
            { managerResult = ReactionNotAdvanced,
              commandResults = commands,
              timerEffects = timers
            }
    AdvanceReaction sagaCommand unconditional acceptedOnly -> do
      existing <- firstExistingEventId options sagaStreamName managerProbes
      case existing of
        Just matchedId -> recoverAndFinish matchedId (unconditional <> acceptedOnly)
        Nothing -> do
          outcome <-
            runDomainCommandWithSqlEvents
              managerOptions
              (manager ^. #sagaHandler)
              sagaStream
              sagaCommand
              (\_ _ -> runTimerPhaseTx (unconditional <> acceptedOnly))
          case outcome of
            Left commandError -> do
              raced <- firstExistingEventId options sagaStreamName managerProbes
              case raced of
                Just matchedId -> recoverAndFinish matchedId (unconditional <> acceptedOnly)
                Nothing -> pure (Left (ReactionCommandFailed commandError))
            Right (domainOutcome@DomainCommandOutcome {decision = DomainAccepted {}}, Just timers) ->
              finish (ReactionEvaluated domainOutcome) timers (unconditional <> acceptedOnly)
            Right (DomainCommandOutcome {decision = DomainAccepted {}}, Nothing) ->
              Prelude.error "runReactiveProcessManagerOnce: accepted append omitted timer callback result"
            Right (domainOutcome, Nothing) -> do
              raced <- firstExistingEventId options sagaStreamName managerProbes
              case raced of
                Just matchedId -> recoverAndFinish matchedId (unconditional <> acceptedOnly)
                Nothing -> do
                  timers <- runTimerPhase unconditional
                  finish (ReactionEvaluated domainOutcome) timers unconditional
            Right (_, Just _) ->
              Prelude.error "runReactiveProcessManagerOnce: silent decision returned a timer callback result"
  where
    correlationId = (manager ^. #correlate) input
    sourceId = sourceEvent ^. #eventId
    sagaStream = (manager ^. #streamFor) correlationId
    sagaEventStream = (manager ^. #sagaHandler) ^. #eventStream
    sagaStreamName = ((unvalidated sagaEventStream) ^. #resolveStreamName) sagaStream
    managerProbes = deterministicCommandIdProbes (manager ^. #name) correlationId sourceId (-1)
    managerId = NonEmpty.head managerProbes
    managerOptions = options & #eventIds .~ [managerId]

    recoverAndFinish matchedId selected = do
      recovered <- recoverWitness sagaEventStream sagaStreamName matchedId
      case recovered of
        Left err -> pure (Left err)
        Right () -> finish (ReactionDuplicate matchedId) zeroTimerEffects selected

    finish state timers selected = do
      commands <- dispatchReactionCommands options manager correlationId sourceId selected
      pure
        $ Right
          ReactiveProcessManagerResult
            { managerResult = state,
              commandResults = commands,
              timerEffects = timers
            }

-- | Execute just the timer subsequence in one transaction.
runTimerPhase :: (Store :> es) => [FollowUp targetCi] -> Eff es ReactionTimerEffects
runTimerPhase followUps = runTransaction (runTimerPhaseTx followUps)

runTimerPhaseTx :: [FollowUp targetCi] -> Tx.Transaction ReactionTimerEffects
runTimerPhaseTx = foldM step zeroTimerEffects
  where
    step summary = \case
      FollowDispatch {} -> pure summary
      FollowSchedule Rearm request -> do
        scheduleTimerTx request
        pure summary {statementsCommitted = summary ^. #statementsCommitted Prelude.+ 1}
      FollowSchedule Once request -> do
        inserted <- scheduleTimerOnceTx request
        pure
          summary
            { statementsCommitted = summary ^. #statementsCommitted Prelude.+ 1,
              onceInserted = summary ^. #onceInserted Prelude.+ if inserted then 1 else 0
            }
      FollowCancel timerId -> do
        cancelled <- cancelTimerTx timerId
        pure
          summary
            { statementsCommitted = summary ^. #statementsCommitted Prelude.+ 1,
              timersCancelled = summary ^. #timersCancelled Prelude.+ if cancelled then 1 else 0
            }

-- | Validate the exact accepted event while holding only one page at a time.
-- The stream version captured after the positive point probe is a finite read
-- ceiling, so a vanished witness cannot chase concurrent appends forever.
recoverWitness ::
  (Store :> es) =>
  ValidatedEventStream phi rs s ci co ->
  StreamName ->
  EventId ->
  Eff es (Either ReactionError ())
recoverWitness validated streamName witnessId = do
  streamInfo <- getStream streamName
  case streamInfo of
    Nothing -> pure (Left missing)
    Just info -> scan (info ^. #id) (info ^. #version) (StreamVersion 0)
  where
    missing = ReactionWitnessMissing streamName witnessId
    codec = (unvalidated validated) ^. #eventCodec
    pageSize = 256

    scan expectedStreamId ceiling cursor = do
      page <- readStreamForward streamName cursor pageSize
      let withinCeiling = Vector.takeWhile (\event -> event ^. #streamVersion <= ceiling) page
          found = Vector.find (\event -> event ^. #eventId == witnessId) withinCeiling
      case found of
        Just witness
          | witness ^. #originalStreamId /= expectedStreamId -> pure (Left missing)
          | otherwise ->
              pure
                $ case decodeRecorded codec witness of
                  Left _ -> Left (ReactionWitnessUndecodable streamName witnessId)
                  Right _ -> Right ()
        Nothing
          | Vector.null withinCeiling -> pure (Left missing)
          | otherwise ->
              let next = (Vector.last withinCeiling) ^. #streamVersion
               in if next >= ceiling
                    then pure (Left missing)
                    else scan expectedStreamId ceiling next

dispatchReactionCommands ::
  forall input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp ->
  Text ->
  EventId ->
  [FollowUp targetCi] ->
  Eff es [PMCommandResult (EventStream targetPhi targetRs targetState targetCi targetCo)]
dispatchReactionCommands options manager correlationId sourceId =
  go Map.empty []
  where
    go _ results [] = pure (Prelude.reverse results)
    go occurrences results (followUp : rest) =
      case followUp of
        FollowDispatch dispatched -> do
          let targetStream = retarget (dispatched ^. #target)
              targetName = ((unvalidated (manager ^. #targetEventStream)) ^. #resolveStreamName) targetStream
              occurrence = Map.findWithDefault 0 targetName occurrences
              nextOccurrences = Map.insert targetName (occurrence Prelude.+ 1) occurrences
              commandId =
                deterministicReactionCommandId
                  (manager ^. #name)
                  correlationId
                  sourceId
                  targetName
                  occurrence
          result <- dispatchOne targetStream targetName commandId dispatched
          result `Prelude.seq` go nextOccurrences (result : results) rest
        _ -> go occurrences results rest

    dispatchOne targetStream targetName commandId dispatched = do
      let targetOptions = options & #eventIds .~ [commandId]
      initial <-
        dispatchDeduplicatedCommand
          options
          targetName
          (commandId :| [])
          PMCommandDuplicate
          (PMCommandFailed targetName)
          PMCommandAppended
          ( runCommandWithProjections
              targetOptions
              (manager ^. #targetEventStream)
              targetStream
              (dispatched ^. #command)
              ((manager ^. #targetProjections) (dispatched ^. #target))
          )
      case initial of
        PMCommandFailed {} -> reconcile initial
        PMCommandAppended commandResult
          | commandResult ^. #eventsAppended == 0 -> reconcile initial
        _ -> pure initial
      where
        reconcile preserved = do
          raced <- firstExistingEventId options targetName (commandId :| [])
          pure (maybe preserved PMCommandDuplicate raced)

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

-- | Derive the stable first-event id for one reaction target command.
--
-- Every field is encoded as its decimal UTF-8 byte length, a colon, and the
-- bytes. The fields are, in order: @keiro@, @process-reaction@, manager name,
-- correlation id, canonical source UUID text, physical target stream name, and
-- decimal zero-based occurrence among commands to that target.
deterministicReactionCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
deterministicReactionCommandId managerName correlationId sourceEventId targetStreamName occurrence =
  EventId
    $ UUID.V5.generateNamed UUID.V5.namespaceURL
    $ ByteString.unpack
    $ ByteString.concat
    $ fmap
      encodeField
      [ "keiro",
        "process-reaction",
        managerName,
        correlationId,
        UUID.toText (coerce sourceEventId),
        coerce targetStreamName,
        Text.pack (show occurrence)
      ]
  where
    encodeField field =
      let bytes = Text.Encoding.encodeUtf8 field
       in ByteString.concat
            [ ByteString.Char8.pack (show (ByteString.length bytes)),
              ByteString.singleton 58,
              bytes
            ]
