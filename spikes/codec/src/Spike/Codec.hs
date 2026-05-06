-- | The spike's value-level codec record. Per EP-2's M0.2 verdict,
-- this is the "selectively borrow from hindsight" shape: a closed
-- record carrying encode + decode + type-tag + current-version +
-- an explicit chain of consecutive upcasters. The shape stays
-- value-level (no type families, no Peano-numbered Upcast n
-- instances) so it composes with kiroku's runtime
-- @event_type :: Text@ registry without a Symbol-to-Text bridge.
--
-- Schema versions are recorded on the wire under
-- @EventData.metadata.schemaVersion :: Int@ — *not* mixed into the
-- type tag — so a projection subscribed by @event_type@ keeps
-- working when payloads evolve. Default is 1 when the field is
-- missing, accommodating events recorded before this convention
-- existed.
--
-- The 'codecUpcasters' list maps source-version @n@ to the
-- transformation @n -> n+1@. Entries must be ascending and
-- contiguous; gaps are rejected by 'migrateToCurrent' at decode
-- time. Decoding an event of version @v@ runs every upcaster from
-- @v@ to @codecVersion - 1@ then hands the result to
-- 'codecDecode'.
module Spike.Codec
  ( -- * The codec record
    Codec (..)
    -- * Encoder
  , encodeForAppend
    -- * Decoder
  , decodeRecorded
  , decodeRaw
  , migrateToCurrent
    -- * Errors
  , DecodeError (..)
    -- * Helpers (exposed for tests)
  , extractSchemaVersion
  , metadataFor
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (Value (..))
import qualified Data.Aeson.Types as Aeson
import Data.Text (Text)
import qualified Data.Text as T

import Kiroku.Store.Types
  ( EventData (..)
  , EventType (..)
  , RecordedEvent (..)
  )


-- | Codec for a single event sum @e@. Per the EP-2 design, the
-- four codec functions plus the @codecVersion@ + @codecUpcasters@
-- pair are sufficient to encode any current-version event for
-- append and decode any previously-recorded version of the same
-- event back to the latest typed shape.
data Codec e = Codec
  { codecEncode    :: e -> Value
    -- ^ Encode a current-version event to its JSON wire shape.
  , codecDecode    :: Value -> Either String e
    -- ^ Decode a JSON value already at @codecVersion@ into @e@.
  , codecTypeTag   :: e -> Text
    -- ^ Stable per-event-constructor wire tag, written into
    -- kiroku's @event_type@ column. Independent of schema version.
  , codecVersion   :: Int
    -- ^ The codec's current schema version. Events written today
    -- carry this value in @EventData.metadata.schemaVersion@; old
    -- events on disk may carry any 'Int' less than this.
  , codecUpcasters :: [(Int, Value -> Either String Value)]
    -- ^ Consecutive upcasters. Entry @(n, f)@ migrates a JSON
    -- value of version @n@ to a JSON value of version @n + 1@.
    -- Entries must be ascending and contiguous; gaps cause a
    -- 'GapInUpcasterChain' error at decode time.
  }


-- | Errors that can surface while decoding a 'RecordedEvent'.
data DecodeError
  = -- | The recorded version is older than any upcaster covers
    -- (smaller than the lowest entry in 'codecUpcasters').
    UnknownVersion !Int
  | -- | An upcaster step rejected its input. Carries the source
    -- version and the upcaster's error message.
    UpcasterError !Int !String
  | -- | The final decode of the migrated payload failed.
    DecodeFailed !String
  | -- | Two non-consecutive entries in 'codecUpcasters'. Carries
    -- the (skipped-from, skipped-to) pair.
    GapInUpcasterChain !Int !Int
  deriving stock (Eq, Show)


-- | The metadata key under which the schema version is stored.
schemaVersionKey :: K.Key
schemaVersionKey = "schemaVersion"


-- | Encode a current-version event into an 'EventData' suitable
-- for 'Kiroku.Store.Append.appendToStream'. Sets
-- @event_type = codecTypeTag e@ and
-- @metadata.schemaVersion = codecVersion@; leaves @event_id@,
-- @causation_id@, and @correlation_id@ as 'Nothing' so kiroku
-- assigns a UUIDv7 and the caller can layer correlation ids
-- separately.
encodeForAppend :: Codec e -> e -> EventData
encodeForAppend c e = EventData
  { eventId       = Nothing
  , eventType     = EventType (codecTypeTag c e)
  , payload       = codecEncode c e
  , metadata      = Just (metadataFor (codecVersion c))
  , causationId   = Nothing
  , correlationId = Nothing
  }


-- | The default metadata object for a fresh-write — only the
-- schema version. Callers that want to enrich the metadata
-- (correlation context, trace ids, tenant tags, …) merge on top
-- of this.
metadataFor :: Int -> Value
metadataFor ver = Object (KM.singleton schemaVersionKey (Number (fromIntegral ver)))


-- | Decode a 'RecordedEvent' through the codec's upcaster chain.
-- Reads the schema version from @metadata@ (default 1 if the
-- field is missing or the record carries no metadata), runs every
-- intermediate upcaster, and finally calls 'codecDecode'.
decodeRecorded :: Codec e -> RecordedEvent -> Either DecodeError e
decodeRecorded c rec = decodeRaw c (extractSchemaVersion rec) (rec.payload)


-- | Decode a raw @(version, payload)@ pair. Used for the spike's
-- driver to feed a hand-crafted v1-shaped JSON record without
-- going through 'RecordedEvent' construction.
decodeRaw :: Codec e -> Int -> Value -> Either DecodeError e
decodeRaw c srcVer payload = do
  migrated <- migrateToCurrent c srcVer payload
  case codecDecode c migrated of
    Right e  -> Right e
    Left msg -> Left (DecodeFailed msg)


-- | Walk the upcaster chain from @srcVer@ to @codecVersion - 1@,
-- applying each transformation in order. Returns the migrated
-- 'Value', ready for 'codecDecode'.
--
-- Validation: the chain entries must be ascending and contiguous;
-- a gap (e.g. entries for versions 1 and 3 but not 2) raises
-- 'GapInUpcasterChain'. A request to decode a version newer than
-- @codecVersion@ is treated as the identity (we have nothing to
-- migrate forward through; the decoder will fail loudly if the
-- shape doesn't match).
migrateToCurrent :: Codec e -> Int -> Value -> Either DecodeError Value
migrateToCurrent c srcVer payload
  | srcVer >= codecVersion c = Right payload   -- already current (or newer)
  | otherwise                = walk srcVer payload
  where
    walk :: Int -> Value -> Either DecodeError Value
    walk v acc
      | v >= codecVersion c = Right acc
      | otherwise           = case lookup v (codecUpcasters c) of
          Nothing ->
            -- No upcaster covers this version. Either the chain has a gap or
            -- the source version pre-dates the codec's earliest covered version.
            case nextChainStart (codecUpcasters c) v of
              Just next -> Left (GapInUpcasterChain v next)
              Nothing   -> Left (UnknownVersion v)
          Just f -> case f acc of
            Left err   -> Left (UpcasterError v err)
            Right acc' -> walk (v + 1) acc'

    nextChainStart :: [(Int, a)] -> Int -> Maybe Int
    nextChainStart entries v =
      case [n | (n, _) <- entries, n > v] of
        (n : _) -> Just n
        []      -> Nothing


-- | Read the schema version off a 'RecordedEvent.metadata'. Falls
-- back to 1 if the field is missing or the metadata is absent —
-- old records predating the convention are interpreted as v1.
extractSchemaVersion :: RecordedEvent -> Int
extractSchemaVersion rec = case rec.metadata of
  Nothing  -> 1
  Just val -> case Aeson.parseEither parser val of
    Right v -> v
    Left _  -> 1
  where
    parser :: Value -> Aeson.Parser Int
    parser = Aeson.withObject "metadata" $ \obj ->
      case KM.lookup schemaVersionKey obj of
        Just (Number n) -> case Aeson.parseEither Aeson.parseJSON (Number n) of
          Right v -> pure (v :: Int)
          Left _  -> pure 1
        _               -> pure 1


-- The Text / show plumbing keeps unused-imports happy.
_unused :: Text
_unused = T.empty
