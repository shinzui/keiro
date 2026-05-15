module Keiro.ProcessManager
  ( ProcessManager (..)
  , ProcessManagerAction (..)
  , ProcessManagerResult (..)
  , PMCommand (..)
  , PMCommandResult (..)
  , PMStateResult (..)
  , deterministicCommandId
  , runProcessManagerOnce
  , runProcessManagerWorker
  )
where

import Data.Coerce (coerce)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError (..), CommandResult, RunCommandOptions, runCommand, runCommandWithSql)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.Stream (Stream)
import Keiro.Timer (TimerRequest, scheduleTimerTx)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Types (EventId (..), RecordedEvent)
import Kiroku.Store.Types qualified as StoreTypes
import Prelude (fromIntegral, length, uncurry, zip)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly

data ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo = ProcessManager
  { name :: !Text
  , correlate :: !(input -> Text)
  , eventStream :: !(EventStream phi rs s ci co)
  , streamFor :: !(Text -> Stream (EventStream phi rs s ci co))
  , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
  , handle :: !(input -> ProcessManagerAction ci targetCi)
  }
  deriving stock (Generic)

data ProcessManagerAction ci targetCi = ProcessManagerAction
  { command :: !ci
  , commands :: ![PMCommand targetCi]
  , timers :: ![TimerRequest]
  }
  deriving stock (Generic)

data PMCommand targetCi = PMCommand
  { target :: !(Stream targetCi)
  , command :: !targetCi
  }
  deriving stock (Generic, Eq, Show)

data PMCommandResult target
  = PMCommandAppended !(CommandResult target)
  | PMCommandDuplicate !EventId
  | PMCommandFailed !CommandError
  deriving stock (Generic, Eq, Show)

data PMStateResult target
  = PMStateAppended !(CommandResult target)
  | PMStateDuplicate !EventId
  deriving stock (Generic, Eq, Show)

data ProcessManagerResult managerTarget commandTarget = ProcessManagerResult
  { managerResult :: !(PMStateResult managerTarget)
  , commandResults :: ![PMCommandResult commandTarget]
  , timersScheduled :: !Int
  }
  deriving stock (Generic, Eq, Show)

deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
deterministicCommandId managerName correlationId sourceEventId emitIndex =
  EventId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
      Text.unpack $
        Text.intercalate
          ":"
          [ "keiro"
          , "process-manager"
          , managerName
          , correlationId
          , UUID.toText (eventIdToUuid sourceEventId)
          , Text.pack (show emitIndex)
          ]

runProcessManagerOnce ::
  forall input phi rs s ci co targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack
  , IOE :> es
  , Store :> es
  , Error StoreError :> es
  , BoolAlg phi (RegFile rs, ci)
  , BoolAlg targetPhi (RegFile targetRs, targetCi)
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
      managerStreamName = ((manager ^. #eventStream) ^. #streamName) managerStream
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
        Left (StoreFailed (DuplicateEvent (Just duplicateId))) | duplicateId == managerEventId ->
          finish correlationId (PMStateDuplicate managerEventId) action
        Left (StoreFailed (DuplicateEvent Nothing)) ->
          finish correlationId (PMStateDuplicate managerEventId) action
        Left err -> pure (Left err)
        Right (managerResult, _) ->
          finish correlationId (PMStateAppended managerResult) action
  where
    finish correlationId managerResult action = do
      commandResults <- dispatchCommands correlationId (sourceEvent ^. #eventId) (action ^. #commands)
      pure $
        Right
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
          targetStreamName = ((manager ^. #targetEventStream) ^. #streamName) targetStream
      commandAlreadyProcessed <- eventAlreadyIn options targetStreamName commandId
      if commandAlreadyProcessed
        then pure (PMCommandDuplicate commandId)
        else do
          outcome <-
            runCommand
              targetOptions
              (manager ^. #targetEventStream)
              targetStream
              (command ^. #command)
          pure $ case outcome of
            Right result -> PMCommandAppended result
            Left (StoreFailed (DuplicateEvent (Just duplicateId))) | duplicateId == commandId -> PMCommandDuplicate commandId
            Left (StoreFailed (DuplicateEvent Nothing)) -> PMCommandDuplicate commandId
            Left err -> PMCommandFailed err

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

runProcessManagerWorker ::
  forall msg input phi rs s ci co targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack
  , IOE :> es
  , Store :> es
  , Error StoreError :> es
  , BoolAlg phi (RegFile rs, ci)
  , BoolAlg targetPhi (RegFile targetRs, targetCi)
  ) =>
  RunCommandOptions ->
  ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runProcessManagerWorker options manager Adapter{source = adapterSource} decodeMessage =
  Streamly.fold Fold.drain $
    Streamly.mapM handleIngested adapterSource
  where
    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested{envelope = Envelope{payload = message}} =
      case decodeMessage message of
        Nothing -> pure (AckHalt (HaltFatal "process-manager worker could not decode message"))
        Just (recorded, input) -> do
          outcome <- runProcessManagerOnce options manager recorded input
          pure $ case outcome of
            Right _ -> AckOk
            Left err -> AckHalt (HaltFatal (Text.pack (show err)))

eventIdToUuid :: EventId -> UUID.UUID
eventIdToUuid (EventId uuid) = uuid

eventAlreadyIn ::
  (Store :> es) =>
  RunCommandOptions ->
  StoreTypes.StreamName ->
  EventId ->
  Eff es Bool
eventAlreadyIn options streamName eventId =
  Streamly.fold
    (Fold.any (\recorded -> recorded ^. #eventId == eventId))
    (readStreamForwardStream streamName (StoreTypes.StreamVersion 0) (options ^. #pageSize))
