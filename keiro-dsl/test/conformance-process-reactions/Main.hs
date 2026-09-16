module Main (main) where

import Control.Monad (unless)
import Data.Aeson (ToJSON)
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (IOE, liftIO, (:>))
import Generated.ProcessReactions.AuditOnly.Process qualified as Audit
import Generated.ProcessReactions.Incident.Domain qualified as Target
import Generated.ProcessReactions.IncidentReaction.Process
import Generated.ProcessReactions.IncidentSaga.Domain qualified as Saga
import Generated.ProcessReactions.Nominals (Severity (..), incidentIdText, mkIncidentId)
import Keiro.Command (defaultRunCommandOptions)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamName (..), StreamVersion (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Stream qualified as Streamly

main :: IO ()
main =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn02q")
      let critical = IncidentReported incidentId Sev1
          routine = IncidentReported incidentId Sev2
          noted = IncidentNoted incidentId
          criticalSource = recorded sourceUuid1 1 "IncidentReported" critical
          routineSource = recorded sourceUuid2 2 "IncidentReported" routine
          notedSource = recorded sourceUuid3 3 "IncidentNoted" noted

      assert "guarded Sev1 arm" $ case incidentReactionReact critical of
        Reaction.AdvanceReaction
          { command = Saga.RecordCritical (Saga.RecordCriticalData recordedId),
            followUps = [Reaction.FollowDispatch (PMCommand _ (Target.EscalateIncident (Target.EscalateIncidentData targetId)))],
            onAccepted = []
          } -> recordedId == incidentId && targetId == incidentId
        _ -> False
      assert "routine otherwise arm" $ case incidentReactionReact routine of
        Reaction.AdvanceReaction
          { command = Saga.RecordRoutine (Saga.RecordRoutineData recordedId),
            followUps = [],
            onAccepted = []
          } -> recordedId == incidentId
        _ -> False
      assert "no-action input" $ case incidentReactionReact noted of
        Reaction.NoAdvance [] -> True
        _ -> False
      assert "timer-free audit process" $ case Audit.auditOnlyReact (Audit.IncidentNoted incidentId) of
        Reaction.NoAdvance [] -> True
        _ -> False

      acknowledgements <- newIORef []
      expectRight
        =<< runStore
          ( incidentReactionRunProcessWorker
              defaultRunCommandOptions
              (inMemoryAdapter "incident-reaction-conformance" acknowledgements [criticalSource, routineSource, notedSource, criticalSource])
          )
      readIORef acknowledgements >>= assert "guard variants, no-action, and duplicate acknowledge" . (== replicate 4 AckOk)

      auditAcks <- newIORef []
      expectRight
        =<< runStore
          ( Audit.auditOnlyRunProcessWorker
              defaultRunCommandOptions
              (inMemoryAdapter "audit-only-conformance" auditAcks [recorded sourceUuid4 4 "IncidentNoted" (Audit.IncidentNoted incidentId)])
          )
      readIORef auditAcks >>= assert "timer-free no-action worker acknowledges" . (== [AckOk])

      let key = incidentIdText incidentId
      sagaEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("incidentSaga-" <> key)) (StreamVersion 0) 10)
      targetEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("incident-" <> key)) (StreamVersion 0) 10)
      auditEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("incidentAudit-" <> key)) (StreamVersion 0) 10)
      assert "both guarded variants append saga events exactly once" (Vector.length sagaEvents == 2)
      assert "only Sev1 dispatches" (Vector.length targetEvents == 1)
      assert "no-action process appends nothing" (Vector.null auditEvents)

      duplicate <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentReactionProcessManager criticalSource critical)
      assert "public once runner observes duplicate witness" $ case duplicate of
        Right result -> case Reaction.managerResult result of
          Reaction.ReactionDuplicate {} -> True
          _ -> False
        Left _ -> False
      putStrLn "process reaction conformance: PASS"

recorded :: (ToJSON input) => UUID -> Int -> Text -> input -> RecordedEvent
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
      createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime (fromIntegral position))
    }

sourceUuid1, sourceUuid2, sourceUuid3, sourceUuid4 :: UUID
sourceUuid1 = staticUuid "123e4567-e89b-72d3-a456-426614174001"
sourceUuid2 = staticUuid "123e4567-e89b-72d3-a456-426614174002"
sourceUuid3 = staticUuid "123e4567-e89b-72d3-a456-426614174003"
sourceUuid4 = staticUuid "123e4567-e89b-72d3-a456-426614174004"

staticUuid :: String -> UUID
staticUuid value = case UUID.fromString value of
  Just parsed -> parsed
  Nothing -> error "invalid static source UUID"

inMemoryAdapter :: (IOE :> es) => Text -> IORef [AckDecision] -> [msg] -> Adapter es msg
inMemoryAdapter name decisions messages =
  Adapter
    { adapterName = name,
      source = Streamly.fromList (map ingest messages),
      shutdown = pure ()
    }
  where
    ingest message =
      Ingested
        { envelope = Envelope "message" Nothing Nothing Nothing Nothing Nothing Nothing mempty message,
          ack = AckHandle (\decision -> liftIO (modifyIORef' decisions (<> [decision]))),
          lease = Nothing
        }

expectRight :: (Show problem) => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("process reaction conformance failed: " <> label))
