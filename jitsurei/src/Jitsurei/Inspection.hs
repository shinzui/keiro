-- | Explicit display encoders for the example application's aggregate catalog.
module Jitsurei.Inspection (jitsureiAggregateInspectors, jitsureiProcessManagerInspectors) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Jitsurei.CreditLimit (creditLimitStateText)
import Jitsurei.CreditLimitStream
import Jitsurei.Domain (stateText)
import Jitsurei.FulfillmentProcess (fulfillmentCategory, fulfillmentProcessManager)
import Jitsurei.Incident (incidentCategory, incidentEventStream)
import Jitsurei.OrderStream (orderCategory, snapshotOrderEventStream)
import Keiki.Codec.JSON (regFileToJSON)
import Keiro.Inspection.Aggregate qualified as Aggregate
import Keiro.ProcessManager.Inspect qualified as PM

jitsureiAggregateInspectors :: Aggregate.AggregateInspectors
jitsureiAggregateInspectors =
  either (error . Text.unpack) id $
    Aggregate.aggregateInspectors
      [ Aggregate.SomeAggregateInspector
          ( (Aggregate.aggregateInspector "order" snapshotOrderEventStream orderCategory (\state registers -> object ["state" .= stateText state, "registers" .= regFileToJSON registers]))
              { Aggregate.stateLabel = stateText
              }
          ),
        Aggregate.SomeAggregateInspector
          ( (Aggregate.aggregateInspector "incident" incidentEventStream incidentCategory (\state registers -> object ["state" .= incidentLabel state, "registers" .= regFileToJSON registers]))
              { Aggregate.stateLabel = incidentLabel
              }
          ),
        Aggregate.SomeAggregateInspector
          ( (Aggregate.aggregateInspector "credit-limit" creditLimitEventStream creditLimitCategory displayCreditLimit)
              { Aggregate.stateLabel = creditLimitStateText
              }
          )
      ]
  where
    incidentLabel = Text.toLower . Text.pack . show

jitsureiProcessManagerInspectors :: PM.ProcessManagerInspectors
jitsureiProcessManagerInspectors =
  Map.singleton
    "jitsurei-fulfillment"
    ( PM.SomeProcessManagerInspector
        (PM.processManagerInspector fulfillmentProcessManager fulfillmentCategory (\state _ -> object ["state" .= Text.pack (show state)]))
    )
