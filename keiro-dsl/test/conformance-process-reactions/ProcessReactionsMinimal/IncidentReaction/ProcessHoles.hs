-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module ProcessReactionsMinimal.IncidentReaction.ProcessHoles (decodeIncidentReactionInput) where

import Generated.ProcessReactionsMinimal.IncidentReaction.Input (IncidentReactionInput)
import Data.Aeson (FromJSON (parseJSON))
import Data.Aeson.Types (parseMaybe)
import Kiroku.Store.Types (RecordedEvent (..))

decodeIncidentReactionInput :: RecordedEvent -> Maybe IncidentReactionInput
decodeIncidentReactionInput event = parseMaybe parseJSON event.payload
