-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module IncidentResponse.IncidentEscalation.ProcessHoles (decodeIncidentEscalationInput) where

import Data.Aeson (parseJSON)
import Data.Aeson.Types (parseMaybe)
import Generated.IncidentResponse.IncidentEscalation.Input (IncidentEscalationInput)
import Kiroku.Store.Types (RecordedEvent (..))

decodeIncidentEscalationInput :: RecordedEvent -> Maybe IncidentEscalationInput
decodeIncidentEscalationInput RecordedEvent {payload} = parseMaybe parseJSON payload
