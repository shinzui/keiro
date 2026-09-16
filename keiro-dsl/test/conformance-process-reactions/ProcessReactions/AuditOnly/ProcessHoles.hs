-- keiro-dsl process-hole contract v1
-- HAND-OWNED typed decoder; created once and never overwritten.
module ProcessReactions.AuditOnly.ProcessHoles (decodeAuditOnlyInput) where

import Data.Aeson (parseJSON)
import Data.Aeson.Types (parseMaybe)
import Generated.ProcessReactions.AuditOnly.Input (AuditOnlyInput)
import Kiroku.Store.Types (RecordedEvent (..))

decodeAuditOnlyInput :: RecordedEvent -> Maybe AuditOnlyInput
decodeAuditOnlyInput RecordedEvent {payload} = parseMaybe parseJSON payload
