-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module CheckedMappingReplay.ReplayReaction.ProcessHoles (decodeReplayReactionInput) where

import Data.Aeson (parseJSON)
import Data.Aeson.Types (parseMaybe)
import Generated.CheckedMappingReplay.ReplayReaction.Input (ReplayReactionInput)
import Kiroku.Store.Types (RecordedEvent (..))

decodeReplayReactionInput :: RecordedEvent -> Maybe ReplayReactionInput
decodeReplayReactionInput RecordedEvent {payload} = parseMaybe parseJSON payload
