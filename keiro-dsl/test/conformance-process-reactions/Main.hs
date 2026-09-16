module Main (main) where

import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (IOE, liftIO, (:>))
import Generated.ProcessReactionsMinimal.Incident.Domain qualified as Target
import Generated.ProcessReactionsMinimal.IncidentReaction.Process
import Generated.ProcessReactionsMinimal.IncidentSaga.Domain qualified as Saga
import Generated.ProcessReactionsMinimal.Nominals (incidentIdText, mkIncidentId)
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
-- Exercise the generated worker through the same PostgreSQL-backed store used by
-- the public runtime tests; the second delivery proves the durable witness path.
main =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn02q")
      let input = IncidentReported incidentId
          sourceEvent = recorded input
          planOk = case incidentReactionReact input of
            Reaction.AdvanceReaction
              { command = Saga.RecordIncident (Saga.RecordIncidentData recordedId),
                followUps = [],
                onAccepted = [Reaction.FollowDispatch (PMCommand _ (Target.EscalateIncident (Target.EscalateIncidentData targetId)))]
              } -> recordedId == incidentId && targetId == incidentId
            _ -> False
      assert "generated accepted reaction" planOk
      assert "generated manager" (incidentReactionProcessManager `seq` True)

      acknowledgements <- newIORef []
      expectRight =<< runStore (incidentReactionRunProcessWorker defaultRunCommandOptions (inMemoryAdapter acknowledgements [sourceEvent, sourceEvent]))
      readIORef acknowledgements >>= assert "one successful acknowledgement per delivery" . (== [AckOk, AckOk])

      let key = incidentIdText incidentId
      sagaEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("incidentSaga-" <> key)) (StreamVersion 0) 10)
      targetEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("incident-" <> key)) (StreamVersion 0) 10)
      assert "one persisted saga event after redelivery" (Vector.length sagaEvents == 1)
      assert "one persisted target event after redelivery" (Vector.length targetEvents == 1)

      duplicate <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentReactionProcessManager sourceEvent input)
      assert "public once runner observes duplicate witness" $ case duplicate of
        Right result -> case result.managerResult of
          Reaction.ReactionDuplicate {} -> True
          _ -> False
        Left _ -> False
      putStrLn "process reaction conformance: PASS"

recorded :: IncidentReactionInput -> RecordedEvent
recorded input =
  RecordedEvent
    { eventId = EventId sourceUuid,
      eventType = EventType "IncidentReported",
      streamVersion = StreamVersion 1,
      globalPosition = GlobalPosition 1,
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion 1,
      payload = Aeson.toJSON input,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
    }

sourceUuid :: UUID.UUID
sourceUuid = case UUID.fromString "123e4567-e89b-72d3-a456-426614174000" of
  Just value -> value
  Nothing -> error "invalid static source UUID"

inMemoryAdapter :: (IOE :> es) => IORef [AckDecision] -> [msg] -> Adapter es msg
inMemoryAdapter decisions messages =
  Adapter
    { adapterName = "process-reaction-conformance",
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

expectRight :: Show problem => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("process reaction conformance failed: " <> label))
