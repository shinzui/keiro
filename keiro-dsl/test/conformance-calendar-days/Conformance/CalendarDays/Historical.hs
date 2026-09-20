module Conformance.CalendarDays.Historical
  ( historicalLocalDayCodec,
    historicalMaybeLocalDayCodec,
  )
where

import Conformance.CalendarDays.Domain (LocalDay (..), MaybeLocalDay (..))
import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.Text qualified as T
import Keiro.Dsl.CodecCompare (HistoricalCodec (..))

-- These repository fixtures model the consumer's pre-adoption Aeson-derived
-- codecs. They are migration evidence, never a runtime fallback.
historicalLocalDayCodec :: HistoricalCodec LocalDay
historicalLocalDayCodec =
  HistoricalCodec
    { identity = "conformance.calendar-days.LocalDay.aeson-day",
      version = "aeson-2.2",
      encode = \(LocalDay value) -> toJSON value,
      decode = either (Left . T.pack) (Right . LocalDay) . parseEither parseJSON
    }

historicalMaybeLocalDayCodec :: HistoricalCodec MaybeLocalDay
historicalMaybeLocalDayCodec =
  HistoricalCodec
    { identity = "conformance.calendar-days.MaybeLocalDay.aeson-day",
      version = "aeson-2.2",
      encode = \(MaybeLocalDay value) -> toJSON value,
      decode = either (Left . T.pack) (Right . MaybeLocalDay) . parseEither parseJSON
    }
