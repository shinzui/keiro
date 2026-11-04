-- | Runtime adapter for the scalar register inspection example.
module Jitsurei.CreditLimitStream
  ( CreditLimitEventStream,
    creditLimitCategory,
    creditLimitStream,
    creditLimitEventStream,
    creditLimitCodec,
    displayCreditLimit,
  )
where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Jitsurei.CreditLimit
import Keiki.Codec.JSON (regFileToJSON)
import Keiki.Core (HsPred, RegFile)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Snapshot (FoldVersion (..), defaultStateCodecWithFold)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Types (EventType (..))

type CreditLimitEventStream = EventStream (HsPred CreditLimitRegs CreditLimitCommand) CreditLimitRegs CreditLimitState CreditLimitCommand CreditLimitEvent

creditLimitCategory :: Stream.StreamCategory a
creditLimitCategory = Stream.categoryUnsafe "creditLimit"

creditLimitStream :: Text -> Stream CreditLimitEventStream
creditLimitStream = Stream.entityStream creditLimitCategory

creditLimitEventStream :: ValidatedEventStream (HsPred CreditLimitRegs CreditLimitCommand) CreditLimitRegs CreditLimitState CreditLimitCommand CreditLimitEvent
creditLimitEventStream =
  mkEventStreamOrThrow "jitsurei-credit-limit" $
    EventStream
      { transducer = creditLimitTransducer,
        initialState = CreditOpen,
        initialRegisters = initialCreditLimitRegs,
        eventCodec = creditLimitCodec,
        resolveStreamName = Stream.streamName,
        -- One command writes the demo's only snapshot; not a production recommendation.
        snapshotPolicy = Every 1,
        -- Bump the fold token whenever transition semantics change.
        stateCodec = Just (defaultStateCodecWithFold @CreditLimitRegs @CreditLimitState (FoldVersion "credit-limit-fold-v1") 1)
      }

creditLimitCodec :: Codec CreditLimitEvent
creditLimitCodec =
  Codec
    { eventTypes = EventType "CreditAdjusted" :| [],
      eventType = const (EventType "CreditAdjusted"),
      schemaVersion = 1,
      encode = \(CreditAdjusted payload) -> object ["delta" .= payload.delta],
      decode = \(EventType tag) value ->
        either (Left . Text.pack) Right $
          parseEither
            ( withObject "CreditAdjusted" $ \fields -> case tag of
                "CreditAdjusted" -> CreditAdjusted . CreditAdjustedData <$> fields .: "delta"
                _ -> fail "unknown credit-limit event type"
            )
            value,
      upcasters = []
    }

displayCreditLimit :: CreditLimitState -> RegFile CreditLimitRegs -> Value
displayCreditLimit state registers =
  object ["state" .= creditLimitStateText state, "registers" .= regFileToJSON registers]
