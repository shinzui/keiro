-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module ProcessTimers.IncidentTimers.ProcessHoles (decodeIncidentTimersInput) where

import Data.Aeson (parseJSON)
import Data.Aeson.Types (parseMaybe)
import Generated.ProcessTimers.IncidentTimers.Input (IncidentTimersInput)
import Kiroku.Store.Types (RecordedEvent (..))

decodeIncidentTimersInput :: RecordedEvent -> Maybe IncidentTimersInput
decodeIncidentTimersInput event = parseMaybe parseJSON event.payload
