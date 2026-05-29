module Keiro.Timer.Types
  ( TimerId (..)
  , TimerRequest (..)
  )
where

import Data.UUID (UUID)
import Keiro.Prelude

newtype TimerId = TimerId UUID
  deriving stock (Generic, Eq, Ord, Show)

data TimerRequest = TimerRequest
  { timerId :: !TimerId
  , processManagerName :: !Text
  , correlationId :: !Text
  , fireAt :: !UTCTime
  , payload :: !Value
  }
  deriving stock (Generic, Eq, Show)
