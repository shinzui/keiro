-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module ProcessReactions.IncidentReaction.ProcessHoles (decodeIncidentReactionInput) where

import Data.Aeson (parseJSON)
import Data.Aeson.Types (parseMaybe)
import Generated.ProcessReactions.IncidentReaction.Input (IncidentReactionInput)
import Kiroku.Store.Types (RecordedEvent (..))

decodeIncidentReactionInput :: RecordedEvent -> Maybe IncidentReactionInput
decodeIncidentReactionInput RecordedEvent {payload} = parseMaybe parseJSON payload
