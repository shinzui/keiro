module Keiro.EventStream
  ( EventStream (..)
  , SnapshotPolicy (..)
  , StateCodec (..)
  )
where

import Keiki.Core (RegFile, SymTransducer)
import Keiro.Codec (Codec)
import Keiro.Prelude
import Keiro.Stream (Stream)
import Kiroku.Store.Types (StreamName, StreamVersion)

data EventStream phi rs s ci co = EventStream
  { transducer :: !(SymTransducer phi rs s ci co)
  , initialState :: !s
  , initialRegisters :: !(RegFile rs)
  , eventCodec :: !(Codec co)
  , streamName :: !(Stream (EventStream phi rs s ci co) -> StreamName)
  , snapshotPolicy :: !(SnapshotPolicy (s, RegFile rs))
  , stateCodec :: !(Maybe (StateCodec (s, RegFile rs)))
  }
  deriving stock (Generic)

data SnapshotPolicy state
  = Never
  | Every !Int
  | OnTerminal
  | Custom !(state -> StreamVersion -> Bool)
  deriving stock (Generic)

data StateCodec state = StateCodec
  { schemaVersion :: !Int
  , shapeHash :: !Text
  , encode :: !(state -> Value)
  , decode :: !(Value -> Either Text state)
  }
  deriving stock (Generic)
