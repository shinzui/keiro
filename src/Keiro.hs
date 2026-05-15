module Keiro
  ( version
  , module Keiro.Command
  , module Keiro.Codec
  , EventStream (..)
  , SnapshotPolicy (..)
  , StateCodec (..)
  , module Keiro.Snapshot
  , module Keiro.Stream
  )
where

import Keiro.Command
import Keiro.Codec
import Keiro.EventStream
import Keiro.Prelude
import Keiro.Snapshot
import Keiro.Stream

version :: Text
version = "0.1.0.0"
