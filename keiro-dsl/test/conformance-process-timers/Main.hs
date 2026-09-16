module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson qualified as Aeson
import Data.Time (UTCTime (..), addUTCTime, getCurrentTime, secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Generated.ProcessTimers.Incident.Codec (incidentCodec)
import Generated.ProcessTimers.Incident.Domain (IncidentEscalatedData (..), IncidentEvent (..))
import Generated.ProcessTimers.IncidentTimers.Process
import Generated.ProcessTimers.Nominals (mkIncidentId)
import Keiro.Codec (decodeRecorded)
import Keiro.Command (defaultRunCommandOptions)
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Test.Postgres (Fixture, StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), TimerStatus (..), claimDueTimer, lookupTimer, markTimerFired, runTimerWorkerWith)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamName (..), StreamVersion (..))

main :: IO ()
main =
  withMigratedSuite $ \fixture -> do
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
      assert "timer identity prefix is pinned" (firstEscalation.timerId == expectedEscalationTimerId)

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

      claimedEscalation <- requireTimer =<< (expectRight =<< runStore (claimDueTimer (addUTCTime 1 escalation2.fireAt)))
      assert "due escalation is claimed before firing" (claimedEscalation.status == Firing)
      fired <- expectRight =<< runStore (incidentTimersFireTimer defaultRunCommandOptions claimedEscalation)
      assert "generated firer returns its deterministic event id" (fired /= Nothing)
      redelivered <- expectRight =<< runStore (incidentTimersFireTimer defaultRunCommandOptions claimedEscalation)
      assert "timer fire redelivery confirms the target witness" (redelivered == fired)
      firedId <- maybe (fail "expected escalation fired event id") pure fired
      marked <- expectRight =<< runStore (markTimerFired firstEscalation.timerId firedId)
      assert "claimed escalation reaches terminal fired state" marked

      let thirdInput = IncidentReported incidentId (addUTCTime 600 secondObserved) "third"
      third <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid4 4 thirdInput) thirdInput)
      thirdResult <- expectRight third
      assert "terminal reschedule attempts still commit both statements" (thirdResult.timerEffects == Reaction.ReactionTimerEffects 2 0 0)
      escalationTerminal <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstEscalation.timerId))
      reminderTerminal <- requireTimer =<< (expectRight =<< runStore (lookupTimer firstReminder.timerId))
      assert "rearm does not revive a fired timer" (escalationTerminal.status == Fired && escalationTerminal.fireAt == escalation2.fireAt)
      assert "schedule once does not revive a cancelled timer" (reminderTerminal.status == Cancelled && reminderTerminal.fireAt == reminder1.fireAt)

      targetEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName "incident-inc_01h455vb4pex5vsknk084sn02q") (StreamVersion 0) 10)
      assert "timer firing appends once" (Vector.length targetEvents == 1)
      assert "escalation timer fires the declared command" $
        traverse (decodeRecorded incidentCodec) (Vector.toList targetEvents)
          == Right [IncidentEscalated (IncidentEscalatedData incidentId)]
    absentCancelCase fixture
    claimedCancelRaceCase fixture
    ceilingCase fixture
    putStrLn "process timer conformance: PASS"

absentCancelCase :: Fixture -> IO ()
absentCancelCase fixture =
  withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
    incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn04s")
    let request = incidentTimersReminderTimerRequest "inc_01h455vb4pex5vsknk084sn04s" (addUTCTime 3600 firstObserved) incidentId
        acknowledged = ResponderAcked incidentId
    cancelled <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid5 5 acknowledged) acknowledged)
    cancelledResult <- expectRight cancelled
    assert "absent cancel commits a statement without changing a row" (cancelledResult.timerEffects == Reaction.ReactionTimerEffects 1 0 0)
    absent <- expectRight =<< runStore (lookupTimer request.timerId)
    assert "absent cancel creates no tombstone" (absent == Nothing)
    let reported = IncidentReported incidentId firstObserved "after-absent-cancel"
    scheduled <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid6 6 reported) reported)
    scheduledResult <- expectRight scheduled
    assert "once schedule inserts after absent cancel" (scheduledResult.timerEffects == Reaction.ReactionTimerEffects 2 1 0)
    _ <- requireTimer =<< (expectRight =<< runStore (lookupTimer request.timerId))
    pure ()

claimedCancelRaceCase :: Fixture -> IO ()
claimedCancelRaceCase fixture =
  withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
    incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn05t")
    let key = "inc_01h455vb4pex5vsknk084sn05t"
        reported = IncidentReported incidentId firstObserved "claim-race"
        escalation = incidentTimersEscalationTimerRequest key (addUTCTime 300 firstObserved) incidentId "claim-race"
        reminder = incidentTimersReminderTimerRequest key (addUTCTime 3600 firstObserved) incidentId
    scheduled <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid7 7 reported) reported)
    _ <- expectRight scheduled
    claimedEscalation <- requireTimer =<< (expectRight =<< runStore (claimDueTimer (addUTCTime 400 firstObserved)))
    escalationEvent <- requireEventId =<< (expectRight =<< runStore (incidentTimersFireTimer defaultRunCommandOptions claimedEscalation))
    escalationMarked <- expectRight =<< runStore (markTimerFired escalation.timerId escalationEvent)
    assert "race setup marks escalation fired" escalationMarked
    claimedReminder <- requireTimer =<< (expectRight =<< runStore (claimDueTimer (addUTCTime 4000 firstObserved)))
    assert "reminder is already claimed before cancellation" (claimedReminder.timerId == reminder.timerId && claimedReminder.status == Firing)
    let acknowledged = ResponderAcked incidentId
    cancelled <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid8 8 acknowledged) acknowledged)
    cancelledResult <- expectRight cancelled
    assert "cancel can race an already claimed timer" (cancelledResult.timerEffects == Reaction.ReactionTimerEffects 1 0 1)
    reminderEvent <- requireEventId =<< (expectRight =<< runStore (incidentTimersFireTimer defaultRunCommandOptions claimedReminder))
    reminderMarked <- expectRight =<< runStore (markTimerFired reminder.timerId reminderEvent)
    assert "cancelled row remains terminal after the claimed fire attempt" (not reminderMarked)
    reminderTerminal <- requireTimer =<< (expectRight =<< runStore (lookupTimer reminder.timerId))
    assert "claimed cancel race leaves the timer cancelled" (reminderTerminal.status == Cancelled)
    targetEvents <- expectRight =<< runStore (Store.readStreamForward (StreamName ("incident-" <> key)) (StreamVersion 0) 10)
    assert "claimed cancel race is harmless under the target state guard" (Vector.length targetEvents == 1)

ceilingCase :: Fixture -> IO ()
ceilingCase fixture =
  withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
    incidentId <- either (fail . show) pure (mkIncidentId "inc_01h455vb4pex5vsknk084sn06v")
    let key = "inc_01h455vb4pex5vsknk084sn06v"
        reported = IncidentReported incidentId firstObserved "ceiling"
        escalation = incidentTimersEscalationTimerRequest key (addUTCTime 300 firstObserved) incidentId "ceiling"
    scheduled <- expectRight =<< runStore (Reaction.runReactiveProcessManagerOnce defaultRunCommandOptions incidentTimersProcessManager (recorded sourceUuid9 9 reported) reported)
    _ <- expectRight scheduled
    now <- getCurrentTime
    forM_ [0 .. 5 :: Int] $ \attempt -> do
      _ <- expectRight =<< runStore (runTimerWorkerWith Nothing incidentTimersTimerWorkerOptions (addUTCTime (fromIntegral (attempt * 400)) now) (\_ -> pure Nothing))
      pure ()
    terminal <- requireTimer =<< (expectRight =<< runStore (lookupTimer escalation.timerId))
    assert "generated attempt ceiling dead-letters before a sixth fire" (terminal.status == Dead && terminal.attempts == 6)

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

expectedEscalationTimerId :: TimerId
expectedEscalationTimerId =
  TimerId
    ( UUID.V5.generateNamed
        UUID.V5.namespaceURL
        (map (fromIntegral . fromEnum) ("incident-escalation-timer:" <> "inc_01h455vb4pex5vsknk084sn02q"))
    )

sourceUuid1, sourceUuid2, sourceUuid3, sourceUuid4, sourceUuid5, sourceUuid6, sourceUuid7, sourceUuid8, sourceUuid9 :: UUID.UUID
sourceUuid1 = staticUuid "123e4567-e89b-72d3-a456-426614174001"
sourceUuid2 = staticUuid "123e4567-e89b-72d3-a456-426614174002"
sourceUuid3 = staticUuid "123e4567-e89b-72d3-a456-426614174003"
sourceUuid4 = staticUuid "123e4567-e89b-72d3-a456-426614174004"
sourceUuid5 = staticUuid "123e4567-e89b-72d3-a456-426614174005"
sourceUuid6 = staticUuid "123e4567-e89b-72d3-a456-426614174006"
sourceUuid7 = staticUuid "123e4567-e89b-72d3-a456-426614174007"
sourceUuid8 = staticUuid "123e4567-e89b-72d3-a456-426614174008"
sourceUuid9 = staticUuid "123e4567-e89b-72d3-a456-426614174009"

staticUuid :: String -> UUID.UUID
staticUuid value = case UUID.fromString value of
  Just uuid -> uuid
  Nothing -> error "invalid static UUID"

requireTimer :: Maybe TimerRow -> IO TimerRow
requireTimer = maybe (fail "expected timer row") pure

requireEventId :: Maybe EventId -> IO EventId
requireEventId = maybe (fail "expected fired event id") pure

expectRight :: Show problem => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error ("process timer conformance failed: " <> label))
