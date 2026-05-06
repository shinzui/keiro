-- | The Counter aggregate packaged into the spike's 'Aggregate'
-- record. EP-2 will replace 'Aeson.toJSON'/'Aeson.fromJSON' with a
-- proper 'Codec co' carrying schema-version evolution; the spike's
-- bare pair is the placeholder.
module Spike.Codec
  ( counterAggregate
  ) where

import qualified Data.Aeson as Aeson

import Spike.Aggregate (Aggregate (..))
import Spike.Counter
  ( CounterCmd
  , CounterEvent
  , CounterRegs
  , CounterVertex
  , counter
  , eventTag
  )
import Keiki.Core (HsPred)


counterAggregate
  :: Aggregate (HsPred CounterRegs CounterCmd)
               CounterRegs
               CounterVertex
               CounterCmd
               CounterEvent
counterAggregate = Aggregate
  { aggTransducer = counter
  , aggEncode     = Aeson.toJSON
  , aggDecode     = decodeJson
  , aggEventTag   = eventTag
  }
  where
    decodeJson :: Aeson.Value -> Either String CounterEvent
    decodeJson v = case Aeson.fromJSON v of
      Aeson.Success x -> Right x
      Aeson.Error   e -> Left e
