module Keiro
  ( version
  , module Keiro.Codec
  , EventStream (..)
  , SnapshotPolicy (..)
  , StateCodec (..)
  , module Keiro.Stream
  )
where

import Keiro.Codec
import Keiro.EventStream
import Keiro.Prelude
import Keiro.Stream

version :: Text
version = "0.1.0.0"
