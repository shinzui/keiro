module Main (main) where

import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Time (UTCTime (..), addUTCTime, secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Generated.ProcessTimers.IncidentTimers.Process
import Generated.ProcessTimers.Nominals (mkIncidentId)
import Keiro.Command (defaultRunCommandOptions)
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Keiro.Timer (TimerRequest (..), TimerRow (..), TimerStatus (..), lookupTimer)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamName (..), StreamVersion (..))

main :: IO ()
main =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn02q")
      let firstInput = IncidentReported incidentId firstObserved "first"
          secondInput = IncidentReported incidentId secondObserved "second"
          firstEvent = recorded sourceUuid1 1 firstInput
          secondEvent = recorded sourceUuid2 2 secondInput
          escalationAt observed = addUTCTime 300 observed
          reminderAt observed = addUTCTime 3600 observed
          firstEscalation = incidentTimersEscalationTimerRequest "inc_01h455vb4pex5vsknk084sn02q" (escalationAt firstObserved) incidentId "first"
          firstReminder = incidentTimersReminderTimerRequest "inc_01h455vb4pex5vsknk084sn02q" (reminderAt firstObserved) incidentId

      first <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager firstEvent firstInput)
      firstResult <- expectRight first
      assert "first delivery committed both timer statements" (firstResult.timerEffects == Reaction.ReactionTimerEffects 2 1 0)

      escalation1 <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstEscalation.timerId))
      reminder1 <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstReminder.timerId))
      assert "rearm timer used the first deadline" (escalation1.fireAt == escalationAt firstObserved)
      assert "once timer used the first deadline" (reminder1.fireAt == reminderAt firstObserved)
      assert "dynamic payload round-trips" $ case Aeson.fromJSON escalation1.payload of
        Aeson.Success EscalationPayload {detail = "first"} -> True
        _ -> False

      second <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager secondEvent secondInput)
      secondResult <- expectRight second
      assert "second accepted source attempted both schedules" (secondResult.timerEffects == Reaction.ReactionTimerEffects 2 0 0)
      escalation2 <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstEscalation.timerId))
      reminder2 <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstReminder.timerId))
      assert "rearm moved the still-scheduled deadline" (escalation2.fireAt == escalationAt secondObserved)
      assert "once preserved the original deadline" (reminder2.fireAt == reminderAt firstObserved)

      replay <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager secondEvent secondInput)
      replayResult <- expectRight replay
      assert "accepted replay skipped timer SQL" (replayResult.timerEffects == Reaction.ReactionTimerEffects 0 0 0)

      cancelled <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid3 3 (ResponderAcked incidentId)) (ResponderAcked incidentId))
      cancelledResult <- expectRight cancelled
      assert "cancel reports its committed and changed counts" (cancelledResult.timerEffects == Reaction.ReactionTimerEffects 1 0 1)
      reminderCancelled <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstReminder.timerId))
      assert "cancelled timer is terminal" (reminderCancelled.status == Cancelled)

      fired <- expectRight =<< runStore (incidentTimersFireTimer defaultRunCommandOptions escalation2)
      assert "generated firer returns its deterministic event id" (fired /= Nothing)
      redelivered <- expectRight =<< runStore (incidentTimersFireTimer defaultRunCommandOptions escalation2)
      assert "timer fire redelivery confirms the target witness" (redelivered == fired)
      targetEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName "incident-inc_01h455vb4pex5vsknk084sn02q") (StreamVersion 0) 10)
      assert "timer firing appends once" (Vector.length targetEvents == 1)
      putStrLn "process timer conformance: PASS"

recorded :: UUID.UUID -> Int -> IncidentTimersInput -> RecordedEvent
recorded eventUuid position input =
  RecordedEvent
    { eventId = EventId eventUuid,
      eventType = EventType "ProcessTimerInput",
      streamVersion = StreamVersion (fromIntegral position),
      globalPosition = GlobalPosition (fromIntegral position),
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion (fromIntegral position),
      payload = Aeson.toJSON input,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = firstObserved
    }

firstObserved :: UTCTime
firstObserved = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)

secondObserved :: UTCTime
secondObserved = addUTCTime 600 firstObserved

sourceUuid1, sourceUuid2, sourceUuid3 :: UUID.UUID
sourceUuid1 = staticUuid "123e4567-e89b-72d3-a456-426614174001"
sourceUuid2 = staticUuid "123e4567-e89b-72d3-a456-426614174002"
sourceUuid3 = staticUuid "123e4567-e89b-72d3-a456-426614174003"

staticUuid :: String -> UUID.UUID
staticUuid value = case UUID.fromString value of
  Just uuid -> uuid
  Nothing -> error "invalid static UUID"

requireTimer :: Maybe TimerRow -> IO TimerRow
requireTimer = maybe (fail "expected timer row") pure

expectRight :: Show problem => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("process timer conformance failed: " <> label))
