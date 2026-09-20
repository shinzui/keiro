module Conformance.StructuralTextSets.Historical
  ( historicalTextLabelsCodec,
    historicalMaybeTextLabelsCodec,
  )
where

import Conformance.StructuralTextSets.Domain (MaybeTextLabels (..), TextLabels (..))
import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.Text qualified as T
import Keiro.Dsl.CodecCompare (HistoricalCodec (..))

-- These fixtures model the consumer's pre-adoption Aeson Set instances. They
-- are compatibility evidence only and are never used as runtime fallbacks.
historicalTextLabelsCodec :: HistoricalCodec TextLabels
historicalTextLabelsCodec =
  HistoricalCodec
    { identity = "conformance.structural-text-sets.TextLabels.aeson-set",
      version = "aeson-2.2",
      encode = \(TextLabels value) -> toJSON value,
      decode = either (Left . T.pack) (Right . TextLabels) . parseEither parseJSON
    }

historicalMaybeTextLabelsCodec :: HistoricalCodec MaybeTextLabels
historicalMaybeTextLabelsCodec =
  HistoricalCodec
    { identity = "conformance.structural-text-sets.MaybeTextLabels.aeson-set",
      version = "aeson-2.2",
      encode = \(MaybeTextLabels value) -> toJSON value,
      decode = either (Left . T.pack) (Right . MaybeTextLabels) . parseEither parseJSON
    }
