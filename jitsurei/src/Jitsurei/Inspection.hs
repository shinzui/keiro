-- | Explicit display encoders for the example application's aggregate catalog.
module Jitsurei.Inspection (jitsureiAggregateInspectors) where

import Data.Aeson (object, (.=))
import Data.Text qualified as Text
import Jitsurei.Domain (stateText)
import Jitsurei.Incident (incidentCategory, incidentEventStream)
import Jitsurei.OrderStream (orderCategory, snapshotOrderEventStream)
import Keiro.Inspection.Aggregate qualified as Aggregate

jitsureiAggregateInspectors :: Aggregate.AggregateInspectors
jitsureiAggregateInspectors =
  either (error . Text.unpack) id $
    Aggregate.aggregateInspectors
      [ Aggregate.SomeAggregateInspector
          ( (Aggregate.aggregateInspector "order" snapshotOrderEventStream orderCategory (\state _ -> object ["state" .= stateText state]))
              { Aggregate.stateLabel = stateText
              }
          ),
        Aggregate.SomeAggregateInspector
          ( (Aggregate.aggregateInspector "incident" incidentEventStream incidentCategory (\state _ -> object ["state" .= incidentLabel state]))
              { Aggregate.stateLabel = incidentLabel
              }
          )
      ]
  where
    incidentLabel = Text.toLower . Text.pack . show
