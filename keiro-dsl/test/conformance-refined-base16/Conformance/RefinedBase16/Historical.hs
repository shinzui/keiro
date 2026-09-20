module Conformance.RefinedBase16.Historical
  ( historicalContentHashCodec,
  )
where

import Conformance.RefinedBase16.Domain (ContentHash (..))
import Data.Aeson.Types (parseEither)
import Data.Text qualified as T
import Keiro.Codec.Refined (encodeBase16Bytes, parseBase16Bytes)
import Keiro.Dsl.CodecCompare (HistoricalCodec (..))

-- Repository fixture modeled on the consumer's pre-adoption case-insensitive
-- base16 reader and lowercase writer. Real retained Rei history is Plan 295.
historicalContentHashCodec :: HistoricalCodec ContentHash
historicalContentHashCodec =
  HistoricalCodec
    { identity = "mori://shinzui/rei ContentHash repository fixture",
      version = "base16-v1",
      encode = \(ContentHash bytes) -> encodeBase16Bytes bytes,
      decode = either (Left . T.pack) (Right . ContentHash) . parseEither parseBase16Bytes
    }
