module Main (main) where

import Control.Monad (unless)
import Data.Aeson (ToJSON)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Generated.IncidentResponse.Incident.Domain qualified as Target
import Generated.IncidentResponse.Incident.EventStream (incidentCategory, incidentEventStream)
import Generated.IncidentResponse.IncidentEscalation.Process
import Generated.IncidentResponse.Nominals (incidentIdText, mkIncidentId)
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions, runCommand)
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..))
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Stream qualified as Stream
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamName (..), StreamVersion (..))

main :: IO ()
main =
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
      putStrLn "process state-authority conformance: PASS"

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

sourceUuid1, sourceUuid2 :: UUID
sourceUuid1 = staticUuid "123e4567-e89b-72d3-a456-426614174011"
sourceUuid2 = staticUuid "123e4567-e89b-72d3-a456-426614174012"

staticUuid :: String -> UUID
staticUuid value = case UUID.fromString value of
  Just parsed -> parsed
  Nothing -> error "invalid static source UUID"

expectRight :: (Show problem) => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("process state-authority conformance failed: " <> label))
