module MappedRegisterConstruction.Lifecycle.BehaviorHoles (behaviorWitnesses) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Generated.MappedRegisterConstruction.Lifecycle.BehaviorContract
import Generated.MappedRegisterConstruction.Lifecycle.Domain

-- Every required source/command pair gets an executable consumer witness.
behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements
  where
    time = UTCTime (fromGregorian 2026 10 14) 12345
    witness requirement = LiveWitness
      { key = requirement.key,
        history = historyFor requirement,
        command = commandFor requirement.commandName,
        expected = case requirement.kind of
          RequiredRejection -> Rejects RejectNoMatchingEdge
          LiveTransition -> Emits (eventFor requirement.commandName :| [])
          ReplayTransition -> error "fixture has no replay-only transitions"
      }
    historyFor requirement = case requirement.source of
      LifecycleEmpty -> []
      LifecycleAwake -> [Created (CreatedData False)]
      LifecycleDormant -> [Created (CreatedData (requirement.target == Just LifecycleAwake)), Marked (MarkedData time)]
      LifecycleClosed -> [Created (CreatedData False), ClosedEvent (ClosedEventData time)]
    commandFor "Create" = Create (CreateData False)
    commandFor "Mark" = Mark (MarkData time)
    commandFor "Ping" = Ping (PingData time)
    commandFor "Awaken" = Awaken (AwakenData time)
    commandFor "Close" = Close (CloseData time)
    commandFor "Reopen" = Reopen (ReopenData time)
    commandFor _ = error "unknown fixture command"
    eventFor "Create" = Created (CreatedData False)
    eventFor "Mark" = Marked (MarkedData time)
    eventFor "Ping" = Pinged (PingedData time)
    eventFor "Awaken" = Awakened (AwakenedData time)
    eventFor "Close" = ClosedEvent (ClosedEventData time)
    eventFor "Reopen" = Reopened (ReopenedData time)
    eventFor _ = error "unknown fixture event"
