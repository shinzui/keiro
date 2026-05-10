-- | The Counter event stream packaged into the spike's 'EventStream'
-- record. EP-2 will replace 'Aeson.toJSON'/'Aeson.fromJSON' with a
-- proper 'Codec co' carrying schema-version evolution; the spike's
-- bare pair is the placeholder.
module Spike.Codec
  ( counterEventStream
  ) where

import qualified Data.Aeson as Aeson

import Spike.EventStream (EventStream (..))
import Spike.Counter
  ( CounterCmd
  , CounterEvent
  , CounterRegs
  , CounterVertex
  , counter
  , eventTag
  )
import Keiki.Core (HsPred)


counterEventStream
  :: EventStream (HsPred CounterRegs CounterCmd)
                 CounterRegs
                 CounterVertex
                 CounterCmd
                 CounterEvent
counterEventStream = EventStream
  { esTransducer = counter
  , esEncode     = Aeson.toJSON
  , esDecode     = decodeJson
  , esEventTag   = eventTag
  }
  where
    decodeJson :: Aeson.Value -> Either String CounterEvent
    decodeJson v = case Aeson.fromJSON v of
      Aeson.Success x -> Right x
      Aeson.Error   e -> Left e
