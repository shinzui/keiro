{-# LANGUAGE OverloadedRecordDot #-}

-- | The bounded, explicitly enabled legacy reaction metadata contract.
-- Kept below the runner and inspector to avoid a dependency cycle.
module Keiro.ProcessManager.Provenance
  ( ReactionProvenance (..),
    legacyProvenanceFamily,
    encodeReactionProvenance,
    decodeReactionProvenance,
    withProvenanceMetadata,
  )
where

import Control.Monad (unless)
import Data.Aeson (Value (..), object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Keiro.Command (RunCommandOptions)
import Keiro.Prelude hiding ((.=))
import Keiro.Timer.Types (TimerId (..))
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), StreamId (..), StreamName (..))

data ReactionProvenance = ReactionProvenance
  { sourceEventId :: !EventId,
    sourceGlobalPosition :: !GlobalPosition,
    sourceStreamId :: !StreamId,
    dispatched :: ![(Int, StreamName)],
    timerIds :: ![TimerId],
    family :: !Text,
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)

legacyProvenanceFamily :: Text
legacyProvenanceFamily = "legacy-positional-v1"

maxEntries, maxBytes :: Int
maxEntries = 64
maxBytes = 16 * 1024

-- | Encode the inner @keiro.pm@ value. Only the supported identity family can
-- be written. Oversized identifiers or frames retain source-only evidence with
-- @truncated=true@; the prefix walks never demand the full follow-up lists.
encodeReactionProvenance :: ReactionProvenance -> Value
encodeReactionProvenance original
  | original.family /= legacyProvenanceFamily = Null
  | any oversized targets = frame sourceOnly
  | not (withinByteBudget value) = frame sourceOnly
  | otherwise = value
  where
    (targets, moreTargets) = prefix original.dispatched
    (timers, moreTimers) = prefix original.timerIds
    bounded = original {dispatched = targets, timerIds = timers, truncated = original.truncated || moreTargets || moreTimers}
    sourceOnly = original {dispatched = [], timerIds = [], truncated = True}
    value = frame bounded
    oversized (_, StreamName name) = Text.length (Text.take (maxBytes + 1) name) > maxBytes
    prefix xs = let (selected, rest) = splitAt maxEntries xs in (selected, not (null rest))

withinByteBudget :: Value -> Bool
withinByteBudget value = Lazy.length (Lazy.take (fromIntegral maxBytes + 1) (Aeson.encode value)) <= fromIntegral maxBytes

frame :: ReactionProvenance -> Value
frame provenance =
  object
    [ "v" .= (1 :: Int),
      "family" .= provenance.family,
      "truncated" .= provenance.truncated,
      "source"
        .= object
          [ "eventId" .= eventText provenance.sourceEventId,
            "globalPosition" .= positionNumber provenance.sourceGlobalPosition,
            "streamId" .= streamNumber provenance.sourceStreamId
          ],
      "dispatched" .= [object ["i" .= index, "target" .= name] | (index, StreamName name) <- provenance.dispatched],
      "timers" .= [UUID.toText timer | TimerId timer <- provenance.timerIds]
    ]
  where
    eventText (EventId uuid) = UUID.toText uuid
    positionNumber (GlobalPosition n) = n
    streamNumber (StreamId n) = n

-- | Decode an inner frame. Missing/unknown versions or identity families are
-- unavailable, never interpreted through another family's deterministic IDs.
decodeReactionProvenance :: Value -> Maybe ReactionProvenance
decodeReactionProvenance = either (const Nothing) Just . parseEither parseFrame
  where
    parseFrame = withObject "legacy reaction provenance" $ \value -> do
      version <- value .: "v" :: Parser Int
      family <- value .: "family"
      unless (version == 1 && family == legacyProvenanceFamily) (fail "unsupported reaction provenance")
      unless (withinByteBudget (Object value)) (fail "provenance exceeds its byte bound")
      (eventId, position, streamId) <-
        value .: "source"
          >>= withObject
            "source"
            ( \source ->
                (,,)
                  <$> (EventId <$> (source .: "eventId" >>= uuidValue))
                  <*> (GlobalPosition <$> source .: "globalPosition")
                  <*> (StreamId <$> source .: "streamId")
            )
      dispatched <-
        value .: "dispatched"
          >>= boundedArray
            ( withObject "dispatch" $ \entry -> do
                index <- entry .: "i"
                unless (index >= (0 :: Int)) (fail "negative emit index")
                (index,) . StreamName <$> entry .: "target"
            )
      timerIds <- value .: "timers" >>= boundedArray (fmap TimerId . uuidValue)
      truncated <- value .: "truncated"
      pure (ReactionProvenance eventId position streamId dispatched timerIds family truncated)
    uuidValue = withText "UUID" (maybe (fail "invalid UUID") pure . UUID.fromText)
    boundedArray parse = \case
      Array values | Vector.length values <= maxEntries -> traverse parse (Vector.toList values)
      _ -> fail "provenance array exceeds its bound"

-- Keep non-object caller values intact for the existing codec rejection. The
-- inner merge remains lazy until encoding, so silent/rejected decisions do not
-- demand provenance or follow-ups merely because capture is enabled.
withProvenanceMetadata :: Value -> RunCommandOptions -> RunCommandOptions
withProvenanceMetadata provenance options =
  options & #metadata .~ case options ^. #metadata of
    Nothing -> Just (object ["keiro.pm" .= provenance])
    Just value -> Just (case value of Object fields -> Object (KeyMap.insert "keiro.pm" provenance fields); _ -> value)
