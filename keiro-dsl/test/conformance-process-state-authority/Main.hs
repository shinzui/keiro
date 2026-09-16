module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (forM_, replicateM, replicateM_, unless)
import Data.Aeson (ToJSON)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Generated.IncidentResponse.Incident.Domain qualified as Target
import Generated.IncidentResponse.Incident.EventStream (incidentCategory, incidentEventStream)
import Generated.IncidentResponse.IncidentEscalation.Process
import Generated.IncidentResponse.Nominals (Severity (..), incidentIdText, mkIncidentId)
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..))
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Stream qualified as Stream
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamName (..), StreamVersion (..))
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = getArgs >>= \case
  [] -> regularMain
  ["--hydration-probe"] -> hydrationProbeMain
  arguments -> fail ("unexpected arguments: " <> show arguments)

regularMain :: IO ()
regularMain =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      incidentId <- either (fail . show) pure (mkIncidentId incidentKey)
      emptyId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn03r")
      let acknowledged = ResponderAcked incidentId observedAt
          source = recorded sourceUuid1 1 "ResponderAcked" acknowledged
          sourceId = source.eventId
          targetName = StreamName ("incident-" <> incidentKey)
          targetStream = Stream.entityStream incidentCategory incidentKey
          dispatchId = Reaction.deterministicReactionCommandId incidentEscalationProcessName incidentKey sourceId targetName 0
          targetCommand = Target.AcknowledgeIncident (Target.AcknowledgeIncidentData incidentId)

      assert "accepted-only dispatch is separated from unconditional cancel" $ case incidentEscalationReact acknowledged of
        Reaction.AdvanceReaction
          { followUps = [Reaction.FollowCancel _],
            onAccepted = [Reaction.FollowDispatch (PMCommand _ (Target.AcknowledgeIncident {}))]
          } -> True
        _ -> False

      -- Seed the target write under the exact generated identity. The manager
      -- then appends the missing saga witness and recovers the target as a
      -- benign duplicate: the partial-success retry contract.
      _ <- expectRight =<< runStore (runCommand (defaultRunCommandOptions {eventIds = [dispatchId]}) incidentEventStream targetStream targetCommand)
      first <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentEscalationProcessManager source acknowledged)
      firstResult <- expectRight first
      assert "partial target success completes only the missing saga write" $ case firstResult.commandResults of
        [PMCommandDuplicate observedId] -> observedId == dispatchId
        _ -> False
      assert "accepted cancel statement records no changed absent timer" (firstResult.timerEffects == Reaction.ReactionTimerEffects 1 0 0)

      replay <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentEscalationProcessManager source acknowledged)
      replayResult <- expectRight replay
      assert "accepted redelivery skips timer SQL" (replayResult.timerEffects == Reaction.ReactionTimerEffects 0 0 0)
      assert "accepted redelivery retries fan-out by stable identity" $ case replayResult.commandResults of
        [PMCommandDuplicate observedId] -> observedId == dispatchId
        _ -> False

      sagaEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("escalation-" <> incidentKey)) (StreamVersion 0) 10)
      targetEvents <- expectRight =<< runStore (Store.readStreamForward targetName (StreamVersion 0) 10)
      assert "recorded saga event authorizes exactly one accepted-only target" (Vector.length sagaEvents == 1 && Vector.length targetEvents == 1)

      let noAdvance = IncidentNoted emptyId
          noAdvanceSource = recorded sourceUuid2 2 "IncidentNoted" noAdvance
      noAdvanceOutcome <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentEscalationProcessManager noAdvanceSource noAdvance)
      noAdvanceResult <- expectRight noAdvanceOutcome
      assert "no-advance performs no accepted-only effects" $ case noAdvanceResult.managerResult of
        Reaction.ReactionNotAdvanced -> null noAdvanceResult.commandResults && noAdvanceResult.timerEffects == Reaction.ReactionTimerEffects 0 0 0
        _ -> False
      absentSaga <- expectRight =<< runStore (Store.getStream (StreamName ("escalation-" <> incidentIdText emptyId)))
      assert "no-advance does not create or hydrate a saga stream" (absentSaga == Nothing)

      silentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn04s")
      let reported = IncidentReported silentId Sev1 observedAt
          reportedSource = recorded sourceUuid3 3 "IncidentReported" reported
          ignored = ResponderIgnored silentId
          ignoredSource = recorded sourceUuid4 4 "ResponderIgnored" ignored
      reportedOutcome <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentEscalationProcessManager reportedSource reported)
      _ <- expectRight reportedOutcome
      silentOutcome <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentEscalationProcessManager ignoredSource ignored)
      silentResult <- expectRight silentOutcome
      assert "silent advance keeps unconditional cancellation and suppresses accepted-only dispatch" $
        null silentResult.commandResults
          && silentResult.timerEffects == Reaction.ReactionTimerEffects 1 0 1
      silentReplay <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentEscalationProcessManager ignoredSource ignored)
      silentReplayResult <- expectRight silentReplay
      assert "silent redelivery remains eligible but has no accepted-only effects" $
        null silentReplayResult.commandResults
          && silentReplayResult.timerEffects == Reaction.ReactionTimerEffects 1 0 0
      silentSaga <- expectRight =<< runStore (Store.readStreamForward (StreamName ("escalation-" <> incidentIdText silentId)) (StreamVersion 0) 10)
      silentTarget <- expectRight =<< runStore (Store.getStream (StreamName ("incident-" <> incidentIdText silentId)))
      assert "silent arm records no saga event of its own and no target event" (Vector.length silentSaga == 1 && silentTarget == Nothing)
      putStrLn "process state-authority conformance: PASS"

hydrationProbeMain :: IO ()
hydrationProbeMain =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn07w")
      let workerCount = 32
          input = IncidentReported incidentId Sev1 observedAt
          run index =
            runStore
              ( Reaction.runReactiveProcessManagerOnce
                  defaultRunCommandOptions
                  incidentEscalationProcessManager
                  (recorded (conflictSourceUuid index) (100 + index) "IncidentReported" input)
                  input
              )
      ready <- newEmptyMVar
      start <- newEmptyMVar
      done <- newEmptyMVar
      forM_ [0 .. workerCount - 1] $ \index -> do
        _ <- forkIO $ do
          putMVar ready ()
          readMVar start
          run index >>= putMVar done
        pure ()
      replicateM_ workerCount (takeMVar ready)
      hPutStrLn stderr "reaction-case-start state-authority-forced-conflict"
      putMVar start ()
      outcomes <- replicateM workerCount (takeMVar done)
      hPutStrLn stderr "reaction-case-end state-authority-forced-conflict"
      assert "forced conflict has at least one accepted append" (any isAccepted outcomes)
      assert "forced conflict observes an optimistic loser" (any isConflict outcomes)
      putStrLn "process state-authority hydration probe: PASS"
  where
    isAccepted = \case
      Right (Right _) -> True
      _ -> False
    isConflict = \case
      Right (Left (Reaction.ReactionCommandFailed _)) -> True
      _ -> False

conflictSourceUuid :: Int -> UUID
conflictSourceUuid index =
  UUID.V5.generateNamed
    UUID.V5.namespaceURL
    (map (fromIntegral . fromEnum) ("state-authority-conflict-" <> show index))

recorded :: (ToJSON input) => UUID -> Int -> EventTypeName -> input -> RecordedEvent
recorded eventUuid position eventName input =
  RecordedEvent
    { eventId = EventId eventUuid,
      eventType = EventType eventName,
      streamVersion = StreamVersion (fromIntegral position),
      globalPosition = GlobalPosition (fromIntegral position),
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion (fromIntegral position),
      payload = Aeson.toJSON input,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = observedAt
    }

type EventTypeName = Text

incidentKey :: Text
incidentKey = "inc_01h455vb4pex5vsknk084sn02q"

observedAt :: UTCTime
observedAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)

sourceUuid1, sourceUuid2, sourceUuid3, sourceUuid4 :: UUID
sourceUuid1 = staticUuid "123e4567-e89b-72d3-a456-426614174011"
sourceUuid2 = staticUuid "123e4567-e89b-72d3-a456-426614174012"
sourceUuid3 = staticUuid "123e4567-e89b-72d3-a456-426614174013"
sourceUuid4 = staticUuid "123e4567-e89b-72d3-a456-426614174014"

staticUuid :: String -> UUID
staticUuid value = case UUID.fromString value of
  Just parsed -> parsed
  Nothing -> error "invalid static source UUID"

expectRight :: (Show problem) => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("process state-authority conformance failed: " <> label))
