-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module TopologyMachine.OrderFlow.ProcessHoles (decodeOrderFlowInput) where

import Generated.TopologyMachine.OrderFlow.Input (OrderFlowInput)
import Kiroku.Store.Types (RecordedEvent)

decodeOrderFlowInput :: RecordedEvent -> Maybe OrderFlowInput
decodeOrderFlowInput = error "fill decodeOrderFlowInput"