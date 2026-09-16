-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module ProcessReactions.ScalingReaction.ProcessHoles (decodeScalingReactionInput) where

import Generated.ProcessReactions.ScalingReaction.Input (ScalingReactionInput)
import Kiroku.Store.Types (RecordedEvent)

decodeScalingReactionInput :: RecordedEvent -> Maybe ScalingReactionInput
decodeScalingReactionInput = error "fill decodeScalingReactionInput"