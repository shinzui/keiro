-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module DeliveryOutcomes.DeliveryStatus.BehaviorHoles (behaviorWitnesses) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Generated.DeliveryOutcomes.DeliveryStatus.BehaviorContract
import Generated.DeliveryOutcomes.DeliveryStatus.Domain
import Generated.DeliveryOutcomes.Nominals (DeliveryNoOp (..))

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ LiveWitness (BehaviorKey "behavior-v1-ac132150262d872a") [] (recordOutcome "delivered") (Emits (outcomeRecorded "delivered" :| [])),
    LiveWitness (BehaviorKey "behavior-v1-ac37ab6d84cb0fa7") [outcomeRecorded "delivered"] (recordOutcome "failed") (NoOpWith AlreadyFinal)
  ]

recordOutcome :: Text -> DeliveryStatusCommand
recordOutcome value = RecordOutcome (RecordOutcomeData value)

outcomeRecorded :: Text -> DeliveryStatusEvent
outcomeRecorded value = OutcomeRecorded (OutcomeRecordedData value)
