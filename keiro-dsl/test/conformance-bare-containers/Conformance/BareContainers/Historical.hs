module Conformance.BareContainers.Historical
  ( historicalMaybeTextCodec,
  )
where

import Conformance.BareContainers.Domain (MaybeText (..))
import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.Text qualified as T
import Keiro.Dsl.CodecCompare (HistoricalCodec (..))

historicalMaybeTextCodec :: HistoricalCodec MaybeText
historicalMaybeTextCodec =
  HistoricalCodec
    { identity = "conformance.bare-containers.MaybeText.opaque-json",
      version = "opaque-v1",
      encode = \(MaybeText value) -> toJSON value,
      decode = either (Left . T.pack) (Right . MaybeText) . parseEither parseJSON
    }
