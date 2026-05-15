module Keiro.Stream
  ( Stream (..)
  , stream
  , streamName
  , mapStreamName
  )
where

import Keiro.Prelude
import Kiroku.Store.Types (StreamName (..))

newtype Stream a = Stream
  { name :: StreamName
  }
  deriving stock (Generic, Eq, Ord, Show)

stream :: Text -> Stream a
stream name = Stream { name = StreamName name }

streamName :: Stream a -> StreamName
streamName value = value ^. #name

mapStreamName :: (StreamName -> StreamName) -> Stream a -> Stream a
mapStreamName f value = value & #name %~ f
