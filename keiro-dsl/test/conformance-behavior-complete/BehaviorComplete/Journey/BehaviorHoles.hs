module BehaviorComplete.Journey.BehaviorHoles (behaviorWitnesses) where

import BehaviorComplete.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Generated.BehaviorComplete.Journey.BehaviorContract
import Generated.BehaviorComplete.Journey.Domain
import Generated.BehaviorComplete.Nominals (RequestId (..))
import Numeric.Natural (Natural)

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ live "behavior-v1-2e1fd6b9580e1a3d" closedHistory pingCommand (Rejects RejectNoOutgoingEdges),
    live "behavior-v1-2f3ebf37a55781db" activeHistory (decideCommand 5) (Emits (decisionEvent 5 :| [])),
    live "behavior-v1-37578058289e05a9" [] (startCommand 0) (Emits (startedEvent 0 :| [])),
    live "behavior-v1-43b8fc7fa48595dd" activeHistory (startCommand 0) (Rejects RejectNoMatchingEdge),
    live "behavior-v1-68e75665b789892c" activeHistory (retireCommand 1) (Emits (retiredEvent 1 :| [retirementAuditedEvent 1])),
    live "behavior-v1-7ea811586a738ee5" closedHistory (decideCommand 1) (Rejects RejectNoOutgoingEdges),
    live "behavior-v1-83b0a46823e1a788" [] pingCommand (Rejects RejectNoMatchingEdge),
    live "behavior-v1-926739ffb27d20e7" [] (retireCommand 1) (Rejects RejectNoMatchingEdge),
    live "behavior-v1-ba7053f86d15e1b0" [] (decideCommand 1) (Rejects RejectNoMatchingEdge),
    live "behavior-v1-be8b08a049ab4d8b" closedHistory (startCommand 0) (Rejects RejectNoOutgoingEdges),
    live "behavior-v1-db1a553baa3eda84" activeHistory (decideCommand 6) (Emits (decisionEvent 6 :| [])),
    live "behavior-v1-ea258e9c47d66aac" activeHistory pingCommand NoOp,
    ReplayWitness (key "behavior-v1-f0fbe3a3ba0b40e8") activeHistory [retiredEvent 0, retirementAuditedEvent 0],
    live "behavior-v1-f9cae2bf4c0d0562" closedHistory (retireCommand 1) (Rejects RejectNoOutgoingEdges)
  ]

live :: Text -> [JourneyEvent] -> JourneyCommand -> LiveExpectation -> BehaviorWitness
live rawKey history command expectation = LiveWitness (key rawKey) history command expectation

key :: Text -> BehaviorKey
key = BehaviorKey

activeHistory :: [JourneyEvent]
activeHistory = [startedEvent 0]

closedHistory :: [JourneyEvent]
closedHistory = activeHistory <> [retiredEvent 1, retirementAuditedEvent 1]

startCommand :: Natural -> JourneyCommand
startCommand amountValue = Start (StartData requestIdValue observedAtValue amountValue payloadValue)

decideCommand :: Natural -> JourneyCommand
decideCommand amountValue = Decide (DecideData amountValue)

pingCommand :: JourneyCommand
pingCommand = Ping (PingData False)

retireCommand :: Natural -> JourneyCommand
retireCommand amountValue = Retire (RetireData amountValue)

startedEvent :: Natural -> JourneyEvent
startedEvent amountValue = Started (StartedData requestIdValue observedAtValue amountValue payloadValue)

decisionEvent :: Natural -> JourneyEvent
decisionEvent amountValue = DecisionRecorded (DecisionRecordedData amountValue)

retiredEvent :: Natural -> JourneyEvent
retiredEvent amountValue = Retired (RetiredData amountValue)

retirementAuditedEvent :: Natural -> JourneyEvent
retirementAuditedEvent amountValue = RetirementAudited (RetirementAuditedData amountValue)

requestIdValue :: RequestId
requestIdValue = RequestId "req_behavior_complete"

observedAtValue :: UTCTime
observedAtValue = UTCTime (fromGregorian 2026 8 1) 0

payloadValue :: Domain.StartPayload
payloadValue = Domain.StartPayload "behavior" (Just "complete")
