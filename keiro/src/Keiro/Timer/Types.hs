{- | Identity and request types for durable timers, separated from their SQL
storage ("Keiro.Timer.Schema") so process-manager code can construct timer
requests without depending on the persistence layer.
-}
module Keiro.Timer.Types (
    TimerId (..),
    TimerRequest (..),
)
where

import Data.UUID (UUID)
import Keiro.Prelude

{- | A timer's stable identifier. A caller-chosen id makes scheduling
idempotent (rescheduling the same id updates rather than duplicates).
-}
newtype TimerId = TimerId UUID
    deriving stock (Generic, Eq, Ord, Show)

{- | A request to schedule a timer.

* 'timerId' — stable id; rescheduling the same id is idempotent.
* 'processManagerName' \/ 'correlationId' — identify the saga instance the
  timer belongs to, so the firing can be routed back to it.
* 'fireAt' — the earliest time the timer becomes due.
* 'payload' — opaque JSON carried through to the @fire@ action.
-}
data TimerRequest = TimerRequest
    { timerId :: !TimerId
    , processManagerName :: !Text
    , correlationId :: !Text
    , fireAt :: !UTCTime
    , payload :: !Value
    }
    deriving stock (Generic, Eq, Show)
